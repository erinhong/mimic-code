-- This query extracts weights for adult ICU patients with start/stop times
-- if an admission weight is given, then this is assigned from intime to outtime

CREATE VIEW `physionet-data.mimiciii_clinical.weightdurations` as

-- This query extracts weights for adult ICU patients with start/stop times
-- if an admission weight is given, then this is assigned from intime to outtime
WITH wt_neonate AS
( 
    SELECT c.icustay_id, c.charttime
    , MAX(CASE WHEN c.itemid = 3580 THEN c.valuenum END) as wt_kg
    , MAX(CASE WHEN c.itemid = 3581 THEN c.valuenum END) as wt_lb
    , MAX(CASE WHEN c.itemid = 3582 THEN c.valuenum END) as wt_oz
    FROM `physionet-data.mimiciii_clinical.chartevents` c
    WHERE c.itemid in (3580, 3581, 3582)
    AND c.icustay_id IS NOT NULL
    AND c.error IS DISTINCT FROM 1
    -- wt_oz/wt_lb/wt_kg are only 0 erroneously, so drop these rows
    AND c.valuenum > 0
  -- a separate query was run to manually verify only 1 value exists per
  -- icustay_id/charttime/itemid grouping
  -- therefore, we can use max() across itemid to collapse these values to 1 row per group
    GROUP BY c.icustay_id, c.charttime
)
, birth_wt AS
(
    SELECT c.icustay_id, c.charttime
    , MAX(
      CASE
      WHEN c.itemid = 4183 THEN
        -- clean free-text birth weight data
        CASE
          -- ignore value if there are any non-numeric characters
          WHEN c.value ~ '[^0-9\.]' THEN NULL 
          -- convert grams to kd
          WHEN CAST(c.value AS NUMERIC) > 100 THEN CAST(c.value AS NUMERIC)/1000
          -- keep kg as is, filtering bad values (largest baby ever born was conveniently 9.98kg)
          WHEN CAST(c.value AS NUMERIC) < 10 THEN CAST(c.value AS NUMERIC)
          -- ignore other values (those between 10-100) - junk data
        ELSE NULL END
      -- itemid 3723 happily has all numeric data - also doesn't store any grams data
      WHEN c.itemid = 3723 AND c.valuenum < 10 THEN c.valuenum
      ELSE NULL END) as wt_kg
    FROM `physionet-data.mimiciii_clinical.chartevents` c
    WHERE c.itemid in (3723, 4183)
    AND c.icustay_id IS NOT NULL
    AND c.error IS DISTINCT FROM 1
  -- a separate query was run to manually verify only 1 value exists per
  -- icustay_id/charttime/itemid grouping
  -- therefore, we can use max() across itemid to collapse these values to 1 row per group
    GROUP BY c.icustay_id, c.charttime
)
, wt_stg as
(
    SELECT
        c.icustay_id
      , c.charttime
      , case when c.itemid in (762,226512) then 'admit'
          else 'daily' end as weight_type
      -- TODO: eliminate obvious outliers if there is a reasonable weight
      , c.valuenum as weight
    FROM `physionet-data.mimiciii_clinical.chartevents` c
    WHERE c.valuenum IS NOT NULL
      AND c.itemid in
      (
          762,226512 -- Admit Wt
        , 763,224639 -- Daily Weight
      )
      AND c.icustay_id IS NOT NULL
      AND c.valuenum > 0
      -- exclude rows marked as error
      AND (c.error IS NULL OR c.error = 0)
    UNION ALL
    SELECT
        n.icustay_id
      , n.charttime
      , 'daily' AS weight_type
      , CASE
          WHEN wt_kg IS NOT NULL THEN wt_kg
          WHEN wt_lb IS NOT NULL THEN wt_lb*0.45359237 + wt_oz*0.0283495231
        ELSE NULL END AS weight
    FROM wt_neonate n
    UNION ALL
    SELECT
        b.icustay_id
      , b.charttime
      -- birth weight of neonates is treated as admission weight
      , 'admit' AS weight_type
      , wt_kg as weight
    FROM birth_wt b
)
-- assign ascending row number
, wt_stg1 as
(
  select
      icustay_id
    , charttime
    , weight_type
    , weight
    , ROW_NUMBER() OVER (partition by icustay_id, weight_type order by charttime) as rn
  from wt_stg
  WHERE weight IS NOT NULL
)
-- change charttime to intime for the first admission weight recorded
, wt_stg2 AS
(
  SELECT 
      wt_stg1.icustay_id
    , ie.intime, ie.outtime
    , case when wt_stg1.weight_type = 'admit' and wt_stg1.rn = 1
        then DATETIME_SUB(ie.intime, INTERVAL 2 HOUR)
      else wt_stg1.charttime end as starttime
    , wt_stg1.weight
  FROM `physionet-data.mimiciii_clinical.icustays` ie
  inner join wt_stg1
    on ie.icustay_id = wt_stg1.icustay_id
)
, wt_stg3 as
(
  select
    icustay_id
    , intime, outtime
    , starttime
    , coalesce(
        LEAD(starttime) OVER (PARTITION BY icustay_id ORDER BY starttime),
        DATETIME_ADD(outtime, INTERVAL 2 HOUR)
      ) as endtime
    , weight
  from wt_stg2
)
-- this table is the start/stop times from admit/daily weight in charted data
, wt1 as
(
  select
      ie.icustay_id
    , wt.starttime
    , case when wt.icustay_id is null then null
      else
        coalesce(wt.endtime,
        LEAD(wt.starttime) OVER (partition by ie.icustay_id order by wt.starttime),
          -- we add a 2 hour "fuzziness" window
        DATETIME_ADD(ie.outtime, INTERVAL 2 HOUR))
      end as endtime
    , wt.weight
  FROM `physionet-data.mimiciii_clinical.icustays` ie
  left join wt_stg3 wt
    on ie.icustay_id = wt.icustay_id
)
-- if the intime for the patient is < the first charted daily weight
-- then we will have a "gap" at the start of their stay
-- to prevent this, we look for these gaps and backfill the first weight
-- this adds (153255-149657)=3598 rows, meaning this fix helps for up to 3598 icustay_id
, wt_fix as
(
  select ie.icustay_id
    -- we add a 2 hour "fuzziness" window
    , DATETIME_SUB(ie.intime, INTERVAL 2 HOUR) as starttime
    , wt.starttime as endtime
    , wt.weight
  FROM `physionet-data.mimiciii_clinical.icustays` ie
  inner join
  -- the below subquery returns one row for each unique icustay_id
  -- the row contains: the first starttime and the corresponding weight
  (
    SELECT wt1.icustay_id, wt1.starttime, wt1.weight
    , ROW_NUMBER() OVER (PARTITION BY wt1.icustay_id ORDER BY wt1.starttime) as rn
    FROM wt1
  ) wt
    ON  ie.icustay_id = wt.icustay_id
    AND wt.rn = 1
    and ie.intime < wt.starttime
)
-- add the backfill rows to the main weight table
, wt2 as
(
  select
      wt1.icustay_id
    , wt1.starttime
    , wt1.endtime
    , wt1.weight
  from wt1
  UNION ALL
  SELECT
      wt_fix.icustay_id
    , wt_fix.starttime
    , wt_fix.endtime
    , wt_fix.weight
  from wt_fix
)
-- get more weights from echo - completes data for ~2500 patients
-- we only use echo data if there is *no* charted data
-- we impute the median echo weight for their entire ICU stay
, echo_lag as
(
  select
    ie.icustay_id
    , ie.intime, ie.outtime
    , 0.453592*ec.weight as weight_echo
    , ROW_NUMBER() OVER (PARTITION BY ie.icustay_id ORDER BY ec.charttime) as rn
    , ec.charttime as starttime
    , LEAD(ec.charttime) OVER (PARTITION BY ie.icustay_id ORDER BY ec.charttime) as endtime
  from `physionet-data.mimiciii_clinical.icustays` ie
  inner join `physionet-data.mimiciii_notes.echodata` ec
      on ie.hadm_id = ec.hadm_id
  where ec.weight is not null
)
, echo_final as
(
    select
        el.icustay_id
        , el.starttime
          -- we add a 2 hour "fuzziness" window
        , coalesce(el.endtime, DATETIME_ADD(el.outtime, INTERVAL 2 HOUR)) as endtime
        , weight_echo
    from echo_lag el
    UNION ALL
    -- if the starttime was later than ICU admission, back-propogate the weight
    select
      el.icustay_id
      , DATETIME_SUB(el.intime, INTERVAL 2 HOUR) as starttime
      , el.starttime as endtime
      , el.weight_echo
    from echo_lag el
    where el.rn = 1
    and el.starttime > DATETIME_SUB(el.intime, INTERVAL 2 HOUR)
)
select
  wt2.icustay_id, wt2.starttime, wt2.endtime, wt2.weight
from wt2
UNION ALL
-- only add echos if we have no charted weight data
select
  ef.icustay_id, ef.starttime, ef.endtime, ef.weight_echo as weight
from echo_final ef
where ef.icustay_id not in (select distinct icustay_id from wt2)
order by icustay_id, starttime, endtime;
