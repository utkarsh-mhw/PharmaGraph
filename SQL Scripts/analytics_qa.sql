-- ============================================
-- PHARMACEUTICAL CLINICAL TRIALS – COMPETITOR PIPELINE ANALYTICS
-- Platform: SQL Server (Azure Data Studio / Azure Databricks SQL compatible)
-- Business Question:
--   Competitor intelligence to assess clinical trial pipeline strength
--   across therapy areas and trial phases for major life science companies.
-- Data Source: ClinicalTrials.gov
-- Entire code including ETL and outputs is available here - [github link]
-- ============================================



CREATE OR ALTER VIEW vw_competitor_pipeline_analytics
AS
WITH
-- -------------------------
-- TERM-SCOPED BASE DATA
-- -------------------------
base_trials AS (
    SELECT
        st.study_id,
        st.nct_number,
        st.study_status,
        st.start_date,
        st.enrollment,
        sp.sponsor_name,
        sp.sponsor_type,
        c.therapy_area,
        p.phase_name,
        p.phase_order
    FROM studies st
    JOIN sponsors sp       ON st.sponsor_id = sp.sponsor_id
    LEFT JOIN conditions c ON st.study_id = c.study_id
    LEFT JOIN study_phases sph ON st.study_id = sph.study_id
    LEFT JOIN phases p     ON sph.phase_id = p.phase_id
    WHERE c.therapy_area IS NOT NULL
),

-- QA check 1: count reconciliation between staging and production data
qa_counts AS (
    SELECT
        COUNT(*) AS production_count,
        (SELECT COUNT(*) FROM staging_raw) AS staging_count
    FROM studies
),

-- QA check 2: enrollment outliers to flag clinical trials with unusually low enrollment
enrollment_stats AS (
    SELECT
        AVG(CAST(enrollment AS FLOAT))  AS avg_enrollment,
        STDEV(CAST(enrollment AS FLOAT)) AS stdev_enrollment
    FROM studies
    WHERE enrollment IS NOT NULL
),

-- Final Aggregation

final_agg AS (
    SELECT
        sponsor_name,
        sponsor_type,
        therapy_area,
        phase_name,
        phase_order,

        COUNT(DISTINCT study_id) AS trial_count,

        AVG(CAST(enrollment AS FLOAT)) AS avg_enrollment,

        SUM(
            CASE
                WHEN enrollment IS NOT NULL
                 AND enrollment < (
                     es.avg_enrollment - 3 * es.stdev_enrollment
                 )
                THEN 1 ELSE 0
            END
        ) AS low_enrollment_outlier_count
    FROM base_trials bt
    CROSS JOIN enrollment_stats es
    GROUP BY
        sponsor_name,
        sponsor_type,
        therapy_area,
        phase_name,
        phase_order
)

-- Power BI report output

SELECT
    fa.sponsor_name,
    fa.sponsor_type,
    fa.therapy_area,
    fa.phase_name,
    fa.phase_order,
    fa.trial_count,
    fa.avg_enrollment,
    fa.low_enrollment_outlier_count,

    -- QA: Count reconciliation status
    CASE
        WHEN qc.production_count = qc.staging_count
        THEN 'PASS'
        ELSE 'FAIL'
    END AS qa_record_count_status,

    -- QA: Date integrity status
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM studies
            WHERE start_date > ISNULL(completion_date, '9999-12-31')
        )
        THEN 'FAIL'
        ELSE 'PASS'
    END AS qa_date_integrity_status

FROM final_agg fa
CROSS JOIN qa_counts qc;
GO