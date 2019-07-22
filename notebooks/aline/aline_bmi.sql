
DROP MATERIALIZED VIEW IF EXISTS ALINE_BMI CASCADE;
CREATE MATERIALIZED VIEW ALINE_BMI as

select
    co.icustay_id
    , case
        when hw.weight_first is not null and hw.height_first is not null
            then (hw.weight_first / (hw.height_first*hw.height_first))
        else null
    end as BMI
    , hw.height_first as height
    , hw.weight_first as weight

from aline_cohort co
left join heightweight hw
  on co.icustay_id = hw.icustay_id
order by co.icustay_id;
