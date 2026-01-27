-- ============================================
-- PHARMACEUTICAL CLINICAL TRIALS INTELLIGENCE PLATFORM
-- ============================================
-- Author: [Your Name]
-- Date: January 2026
-- Purpose: Enterprise SQL reporting system for pharmaceutical pipeline analysis
--
-- BUSINESS CONTEXT:
-- This project simulates data warehouse workflows for a pharmaceutical market
-- intelligence team. The system ingests clinical trial data from ClinicalTrials.gov,
-- transforms it into a normalized relational schema, and powers strategic reporting
-- for competitive analysis, portfolio optimization, and success rate tracking.
--
-- DATA SOURCE: ClinicalTrials.gov export (727 trials across 11 indications, 4 therapy areas)
-- TARGET PLATFORM: PostgreSQL (easily adaptable to SQL Server/Azure Synapse)
-- ============================================

-- ============================================
-- SECTION 1: SCHEMA CREATION
-- ============================================
-- Design Philosophy: Star schema optimized for analytical queries
-- - Fact table: studies (core trial information)
-- - Dimension tables: sponsors, phases, conditions, interventions
-- - Junction table: study_phases (handles many-to-many relationships)

-- Drop existing tables if re-running (cascade removes dependent objects)
DROP TABLE IF EXISTS study_phases CASCADE;
DROP TABLE IF EXISTS interventions CASCADE;
DROP TABLE IF EXISTS conditions CASCADE;
DROP TABLE IF EXISTS studies CASCADE;
DROP TABLE IF EXISTS phases CASCADE;
DROP TABLE IF EXISTS sponsors CASCADE;
DROP TABLE IF EXISTS staging_raw CASCADE;

-- Table 1: Sponsors (Dimension)
-- Purpose: Deduplicate sponsor names, enable aggregation by company
CREATE TABLE sponsors (
    sponsor_id SERIAL PRIMARY KEY,
    sponsor_name VARCHAR(500) UNIQUE NOT NULL,
    sponsor_type VARCHAR(50), -- Industry, Academic, Government
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_sponsors_name ON sponsors(sponsor_name);

-- Table 2: Phases (Dimension - Lookup Table)
-- Purpose: Standardize phase names, enable phase ordering for transition logic
CREATE TABLE phases (
    phase_id SERIAL PRIMARY KEY,
    phase_name VARCHAR(50) UNIQUE NOT NULL,
    phase_order INT NOT NULL, -- 0=N/A, 1=Phase 1, 2=Phase 2, 3=Phase 3, 4=Phase 4
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Pre-populate phases lookup table

INSERT INTO phases (phase_name, phase_order) VALUES
    ('PHASE1', 1),
    ('PHASE2', 2),
    ('PHASE3', 3),
    ('PHASE4', 4),
    ('PHASE1|PHASE2', 1),
    ('PHASE2|PHASE3', 2)
ON CONFLICT (phase_name) DO NOTHING;


-- Table 3: Studies (Fact Table - Core)
-- Purpose: Central fact table containing trial metadata and dates
CREATE TABLE studies (
    study_id SERIAL PRIMARY KEY,
    nct_number VARCHAR(20) UNIQUE NOT NULL,
    sponsor_id INT REFERENCES sponsors(sponsor_id),
    study_title TEXT,
    study_status VARCHAR(100), -- Completed, Terminated, Recruiting, Active not recruiting, etc.
    has_results BOOLEAN DEFAULT FALSE,
    start_date DATE,
    primary_completion_date DATE,
    completion_date DATE,
    enrollment INT,
    study_type VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_studies_nct ON studies(nct_number);
CREATE INDEX idx_studies_sponsor ON studies(sponsor_id);
CREATE INDEX idx_studies_status ON studies(study_status);
CREATE INDEX idx_studies_dates ON studies(start_date, completion_date);

-- Table 4: Study_Phases (Junction Table - Many-to-Many)
-- Purpose: Handle trials that span multiple phases (e.g., "Phase 1/Phase 2")
CREATE TABLE study_phases (
    study_phase_id SERIAL PRIMARY KEY,
    study_id INT REFERENCES studies(study_id) ON DELETE CASCADE,
    phase_id INT REFERENCES phases(phase_id),
    UNIQUE(study_id, phase_id)
);

CREATE INDEX idx_study_phases_study ON study_phases(study_id);
CREATE INDEX idx_study_phases_phase ON study_phases(phase_id);

-- Table 5: Conditions (Dimension)
-- Purpose: Track therapeutic areas and indications for diversity analysis
CREATE TABLE conditions (
    condition_id SERIAL PRIMARY KEY,
    condition_name TEXT,
    study_id INT REFERENCES studies(study_id) ON DELETE CASCADE,
    therapy_area VARCHAR(100), -- Oncology, Cardiology, Neurology, Immunology
    indication VARCHAR(200) -- Specific disease (Lung Cancer, Heart Failure, etc.)
);

CREATE INDEX idx_conditions_study ON conditions(study_id);
CREATE INDEX idx_conditions_therapy_area ON conditions(therapy_area);

-- Table 6: Interventions (Dimension)
-- Purpose: Track drug/treatment names for pipeline analysis
CREATE TABLE interventions (
    intervention_id SERIAL PRIMARY KEY,
    study_id INT REFERENCES studies(study_id) ON DELETE CASCADE,
    intervention_name VARCHAR(500),
    intervention_type VARCHAR(100) -- Drug, Biological, Device, etc.
);

CREATE INDEX idx_interventions_study ON interventions(study_id);


-- ============================================
-- SECTION 2: STAGING TABLE & DATA LOADING
-- ============================================
-- Staging table mimics the structure of the source CSV export
-- This represents the "raw" data ingestion layer before transformation

CREATE TABLE staging_raw (
    nct_number TEXT,
    study_title TEXT,
    study_url TEXT,
    acronym TEXT,
    study_status TEXT,
    brief_summary TEXT,
    study_results TEXT,
    conditions TEXT,
    interventions TEXT,
    primary_outcome_measures TEXT,
    secondary_outcome_measures TEXT,
    other_outcome_measures TEXT,
    sponsor TEXT,
    collaborators TEXT,
    sex TEXT,
    age TEXT,
    phases TEXT,
    enrollment TEXT,
    funder_type TEXT,
    study_type TEXT,
    study_design TEXT,
    other_ids TEXT,
    start_date TEXT,
    primary_completion_date TEXT,
    completion_date TEXT,
    first_posted TEXT,
    results_first_posted TEXT,
    last_update_posted TEXT,
    locations TEXT,
    study_documents TEXT,
    indication TEXT,
    therapy_area TEXT
);


select count(*) from staging_raw;


-- ============================================
-- SECTION 3: ETL TRANSFORMATION
-- ============================================
-- Transform staging data into normalized production tables
-- Handles data cleaning, type conversion, and multi-value field parsing

-- Step 1: Populate Sponsors
-- Deduplicate sponsor names and classify by funder type
INSERT INTO sponsors (sponsor_name, sponsor_type)
SELECT DISTINCT 
    TRIM(sponsor) AS sponsor_name,
    CASE 
        WHEN LOWER(funder_type) LIKE '%industry%' THEN 'Industry'
        WHEN LOWER(funder_type) LIKE '%nih%' OR LOWER(funder_type) LIKE '%government%' THEN 'Government'
        WHEN LOWER(funder_type) LIKE '%other%' THEN 'Academic'
        ELSE 'Unknown'
    END AS sponsor_type
FROM staging_raw
WHERE sponsor IS NOT NULL AND TRIM(sponsor) != ''
ON CONFLICT (sponsor_name) DO NOTHING;

-- Step 2: Populate Studies (Fact Table)
-- Convert string dates to proper DATE types, handle nulls

INSERT INTO studies (
    nct_number, sponsor_id, study_title, study_status, has_results,
    start_date, primary_completion_date, completion_date, enrollment, study_type
)
SELECT DISTINCT ON (sr.nct_number)
    sr.nct_number,
    sp.sponsor_id,
    sr.study_title,
    sr.study_status,
    CASE WHEN LOWER(sr.study_results) = 'yes' THEN TRUE ELSE FALSE END,
    -- Date parsing with validation: only parse if format matches DD/MM/YY
    CASE 
        WHEN sr.start_date ~ '^\d{2}/\d{2}/\d{2}$' THEN TO_DATE(sr.start_date, 'DD/MM/YY')
        ELSE NULL
    END,
    CASE 
        WHEN sr.primary_completion_date ~ '^\d{2}/\d{2}/\d{2}$' THEN TO_DATE(sr.primary_completion_date, 'DD/MM/YY')
        ELSE NULL
    END,
    CASE 
        WHEN sr.completion_date ~ '^\d{2}/\d{2}/\d{2}$' THEN TO_DATE(sr.completion_date, 'DD/MM/YY')
        ELSE NULL
    END,
    CASE WHEN sr.enrollment ~ '^\d+$' THEN sr.enrollment::INT ELSE NULL END,
    sr.study_type
FROM staging_raw sr
LEFT JOIN sponsors sp ON TRIM(sr.sponsor) = sp.sponsor_name
WHERE sr.nct_number IS NOT NULL
ORDER BY sr.nct_number, sr.therapy_area;


-- Step 3: Populate Study_Phases (Junction Table)
-- Parse multi-value phase field (e.g., "Phase 1|Phase 2" → two rows)

INSERT INTO study_phases (study_id, phase_id)
SELECT DISTINCT
    st.study_id,
    p.phase_id
FROM staging_raw sr
JOIN studies st ON sr.nct_number = st.nct_number
CROSS JOIN LATERAL regexp_split_to_table(sr.phases, '\|') AS phase_name_split
JOIN phases p ON TRIM(phase_name_split) = p.phase_name
WHERE sr.phases IS NOT NULL;

-- Step 4: Populate Conditions
-- Map therapy areas and indications to studies
INSERT INTO conditions (study_id, condition_name, therapy_area, indication)
SELECT 
    st.study_id,
    TRIM(sr.conditions) AS condition_name,
    COALESCE(sr.therapy_area, 'Unknown') AS therapy_area,
    sr.indication
FROM staging_raw sr
JOIN studies st ON sr.nct_number = st.nct_number
WHERE sr.conditions IS NOT NULL;

-- Step 5: Populate Interventions
-- Parse comma-separated intervention names
INSERT INTO interventions (study_id, intervention_name, intervention_type)
SELECT DISTINCT
    st.study_id,
    TRIM(regexp_split_to_table(sr.interventions, '\|')) AS intervention_name,
    'Drug' AS intervention_type -- Default to Drug; could parse from intervention string if needed
FROM staging_raw sr
JOIN studies st ON sr.nct_number = st.nct_number
WHERE sr.interventions IS NOT NULL AND TRIM(sr.interventions) != '';

-- ETL Validation: Check record counts
-- Expected: 727 studies, 10-20 sponsors, ~700+ conditions, ~700+ interventions
SELECT 'Sponsors' AS table_name, COUNT(*) AS record_count FROM sponsors
UNION ALL
SELECT 'Studies', COUNT(*) FROM studies
UNION ALL
SELECT 'Study_Phases', COUNT(*) FROM study_phases
UNION ALL
SELECT 'Conditions', COUNT(*) FROM conditions
UNION ALL
SELECT 'Interventions', COUNT(*) FROM interventions;

-- ============================================
-- SECTION 4: ANALYTICAL QUERY 1
-- Phase Transition Success Rates
-- ============================================
-- BUSINESS QUESTION:
-- What percentage of trials successfully transition from Phase 1→2→3?
-- Which sponsors and therapeutic areas have the best success rates?
--
-- METHODOLOGY:
-- 1. Identify all Phase 1 trials that completed (baseline cohort)
-- 2. Check if same sponsor has Phase 2 trials for same therapy area (transition success)
-- 3. Calculate transition rates by sponsor and therapy area
-- 4. Identify factors associated with higher success rates
--
-- OUTPUT: Used in executive dashboard to prioritize therapeutic areas and partners

WITH trial_outcomes AS (
    SELECT 
        sp.sponsor_name,
        c.therapy_area,
        p.phase_name,
        p.phase_order,
        st.study_status,
        CASE 
            WHEN UPPER(st.study_status) IN ('COMPLETED', 'ACTIVE_NOT_RECRUITING') THEN 'Success'
            WHEN UPPER(st.study_status) IN ('TERMINATED', 'WITHDRAWN', 'SUSPENDED') THEN 'Failed'
            WHEN UPPER(st.study_status) IN ('RECRUITING', 'NOT_YET_RECRUITING', 'ENROLLING_BY_INVITATION') THEN 'Ongoing'
            ELSE 'Unknown'
        END AS outcome_category,
        COUNT(*) as trial_count
    FROM studies st
    JOIN study_phases sph ON st.study_id = sph.study_id
    JOIN phases p ON sph.phase_id = p.phase_id
    JOIN sponsors sp ON st.sponsor_id = sp.sponsor_id
    LEFT JOIN conditions c ON st.study_id = c.study_id
    WHERE p.phase_order BETWEEN 1 AND 3
      AND c.therapy_area IS NOT NULL
    GROUP BY sp.sponsor_name, c.therapy_area, p.phase_name, p.phase_order, st.study_status, outcome_category
),

sponsor_therapy_phase_summary AS (
    SELECT 
        sponsor_name,
        therapy_area,
        phase_name,
        phase_order,
        SUM(CASE WHEN outcome_category = 'Success' THEN trial_count ELSE 0 END) as successful_trials,
        SUM(CASE WHEN outcome_category = 'Failed' THEN trial_count ELSE 0 END) as failed_trials,
        SUM(CASE WHEN outcome_category = 'Ongoing' THEN trial_count ELSE 0 END) as ongoing_trials,
        SUM(trial_count) as total_trials
    FROM trial_outcomes
    GROUP BY sponsor_name, therapy_area, phase_name, phase_order
)

SELECT 
    sponsor_name,
    therapy_area,
    phase_name,
    total_trials,
    successful_trials,
    failed_trials,
    ongoing_trials,
    ROUND(100.0 * successful_trials / NULLIF(total_trials, 0), 1) AS success_rate,
    ROUND(100.0 * failed_trials / NULLIF(total_trials, 0), 1) AS failure_rate,
    CASE 
        WHEN total_trials >= 10 THEN 'Established Pharma'
        ELSE 'Emerging Pharma'
    END AS volume_category
FROM sponsor_therapy_phase_summary
WHERE total_trials >= 2  -- Minimum threshold for meaningful analysis
ORDER BY success_rate asc, total_trials DESC
LIMIT 50;

-- ============================================
-- SECTION 5: ANALYTICAL QUERY 2
-- Pipeline Strength Analysis
-- ============================================
-- BUSINESS QUESTION:
-- Which sponsors have the most robust drug development pipelines?
-- Score based on: phase distribution, recent activity, condition diversity
--
-- METHODOLOGY:
-- 1. Calculate weighted phase score (Phase 3 = 5pts, Phase 2 = 3pts, Phase 1 = 1pt)
-- 2. Calculate recency score (trials started in last 2 years weighted higher)
-- 3. Calculate diversity score (number of unique therapeutic areas)
-- 4. Combine into overall pipeline strength ranking
--
-- OUTPUT: Strategic planning tool for partnership prioritization

select start_date from studies;
SELECT DISTINCT "start_date" 
FROM staging_raw 
WHERE "start_date" IS NOT NULL 
LIMIT 10;


WITH active_trials AS (
    -- Filter to trials started in last 5 years
    SELECT 
        st.study_id,
        st.sponsor_id,
        sp.sponsor_name,
        st.start_date,
        st.study_status,
        c.therapy_area,
        c.indication,
        p.phase_order,
        EXTRACT(YEAR FROM CURRENT_DATE) - EXTRACT(YEAR FROM st.start_date) AS years_since_start
    FROM studies st
    JOIN sponsors sp ON st.sponsor_id = sp.sponsor_id
    LEFT JOIN conditions c ON st.study_id = c.study_id
    LEFT JOIN study_phases sph ON st.study_id = sph.study_id
    LEFT JOIN phases p ON sph.phase_id = p.phase_id
    WHERE st.start_date >= CURRENT_DATE - INTERVAL '5 years'
),

phase_scores AS (
    -- Calculate weighted phase score per sponsor
    SELECT 
        sponsor_id,
        sponsor_name,
        COUNT(DISTINCT study_id) AS total_trials,
        SUM(CASE 
            WHEN phase_order = 3 THEN 5
            WHEN phase_order = 2 THEN 3
            WHEN phase_order = 1 THEN 1
            ELSE 0
        END) AS weighted_phase_score
    FROM active_trials
    GROUP BY sponsor_id, sponsor_name
),

recency_scores AS (
    -- Higher score for recent trial starts
    SELECT 
        sponsor_id,
        AVG(CASE 
            WHEN years_since_start <= 1 THEN 5
            WHEN years_since_start <= 2 THEN 4
            WHEN years_since_start <= 3 THEN 3
            WHEN years_since_start <= 4 THEN 2
            ELSE 1
        END) AS recency_score
    FROM active_trials
    WHERE start_date IS NOT NULL
    GROUP BY sponsor_id
),

diversity_scores AS (
    -- Count unique therapeutic areas per sponsor
    SELECT 
        sponsor_id,
        COUNT(DISTINCT therapy_area) AS therapy_area_count,
        COUNT(DISTINCT indication) AS indication_count
    FROM active_trials
    WHERE therapy_area IS NOT NULL
    GROUP BY sponsor_id
)

SELECT 
    ps.sponsor_name,
    ps.total_trials,
    ps.weighted_phase_score,
    ROUND(COALESCE(rs.recency_score, 0), 2) AS recency_score,
    COALESCE(ds.therapy_area_count, 0) AS unique_therapy_areas,
    COALESCE(ds.indication_count, 0) AS unique_indications,
    -- Overall pipeline strength: weighted combination of metrics
    ROUND(
        (ps.weighted_phase_score * 0.4) + 
        (COALESCE(rs.recency_score, 0) * 10 * 0.3) + 
        (COALESCE(ds.therapy_area_count, 0) * 5 * 0.3),
        2
    ) AS overall_pipeline_strength,
    RANK() OVER (ORDER BY 
        (ps.weighted_phase_score * 0.4) + 
        (COALESCE(rs.recency_score, 0) * 10 * 0.3) + 
        (COALESCE(ds.therapy_area_count, 0) * 5 * 0.3) DESC
    ) AS strength_rank,
    CASE 
        WHEN ds.therapy_area_count >= 3 THEN 'Diversified'
        WHEN ds.therapy_area_count = 2 THEN 'Moderately Focused'
        ELSE 'Specialized'
    END AS portfolio_strategy
FROM phase_scores ps
LEFT JOIN recency_scores rs ON ps.sponsor_id = rs.sponsor_id
LEFT JOIN diversity_scores ds ON ps.sponsor_id = ds.sponsor_id
WHERE ps.total_trials >= 3 -- Minimum threshold for meaningful analysis
ORDER BY overall_pipeline_strength DESC
LIMIT 25;

-- ============================================
-- SECTION 6: ANALYTICAL QUERY 3
-- Competitive Positioning Matrix
-- ============================================
-- BUSINESS QUESTION:
-- How do top sponsors position across therapeutic areas and phases?
-- Who dominates specific indications? Who is diversified vs. specialized?
--
-- METHODOLOGY:
-- 1. Identify top 15 sponsors by trial volume
-- 2. Create sponsor × therapy area × phase matrix
-- 3. Calculate market share within each therapy area
-- 4. Identify specialization patterns
--
-- OUTPUT: Competitive intelligence dashboard for strategic positioning

WITH top_sponsors AS (
    -- Identify top 15 sponsors by total trial count
    SELECT 
        sp.sponsor_id,
        sp.sponsor_name,
        COUNT(DISTINCT st.study_id) AS total_trials
    FROM sponsors sp
    JOIN studies st ON sp.sponsor_id = st.sponsor_id
    GROUP BY sp.sponsor_id, sp.sponsor_name
    ORDER BY total_trials DESC
    LIMIT 15
),

sponsor_therapy_phase_matrix AS (
    -- Build sponsor × therapy area × phase combination
    SELECT 
        ts.sponsor_name,
        COALESCE(c.therapy_area, 'Unknown') AS therapy_area,
        p.phase_name,
        p.phase_order,
        COUNT(DISTINCT st.study_id) AS trial_count
    FROM top_sponsors ts
    JOIN studies st ON ts.sponsor_id = st.sponsor_id
    LEFT JOIN conditions c ON st.study_id = c.study_id
    LEFT JOIN study_phases sph ON st.study_id = sph.study_id
    LEFT JOIN phases p ON sph.phase_id = p.phase_id
    GROUP BY ts.sponsor_name, c.therapy_area, p.phase_name, p.phase_order
),

therapy_area_totals AS (
    -- Calculate total trials per therapy area (for market share calculation)
    SELECT 
        therapy_area,
        SUM(trial_count) AS total_trials_in_area
    FROM sponsor_therapy_phase_matrix
    GROUP BY therapy_area
),

market_share AS (
    -- Calculate each sponsor's share within therapeutic areas
    SELECT 
        stpm.sponsor_name,
        stpm.therapy_area,
        stpm.phase_name,
        stpm.phase_order,  -- ADD THIS LINE
        stpm.trial_count,
        tat.total_trials_in_area,
        ROUND(100.0 * stpm.trial_count / NULLIF(tat.total_trials_in_area, 0), 1) AS market_share_pct
    FROM sponsor_therapy_phase_matrix stpm
    JOIN therapy_area_totals tat ON stpm.therapy_area = tat.therapy_area
),

sponsor_specialization AS (
    -- Determine if sponsor is specialized or diversified
    SELECT 
        sponsor_name,
        COUNT(DISTINCT therapy_area) AS therapy_area_count,
        MAX(trial_count) AS max_trials_in_one_area,
        SUM(trial_count) AS total_trials,
        ROUND(100.0 * MAX(trial_count) / NULLIF(SUM(trial_count), 0), 1) AS concentration_pct
    FROM sponsor_therapy_phase_matrix
    GROUP BY sponsor_name
)

-- Final output: Competitive positioning with market share and specialization
SELECT 
    ms.sponsor_name,
    ms.therapy_area,
    ms.phase_name,
    ms.trial_count,
    ms.market_share_pct,
    ss.therapy_area_count AS total_therapy_areas,
    ss.concentration_pct AS top_area_concentration,
    CASE 
        WHEN ss.concentration_pct >= 70 THEN 'Highly Specialized'
        WHEN ss.concentration_pct >= 50 THEN 'Focused'
        WHEN ss.concentration_pct >= 30 THEN 'Balanced'
        ELSE 'Highly Diversified'
    END AS positioning_strategy,
    RANK() OVER (
        PARTITION BY ms.therapy_area, ms.phase_name 
        ORDER BY ms.trial_count DESC
    ) AS rank_in_area_phase
FROM market_share ms
JOIN sponsor_specialization ss ON ms.sponsor_name = ss.sponsor_name
WHERE ms.therapy_area != 'Unknown'
ORDER BY ms.therapy_area, ms.phase_order DESC, ms.trial_count DESC;

-- ============================================
-- END OF PHARMACEUTICAL TRIALS INTELLIGENCE SQL
-- ============================================
-- NOTES FOR DEPLOYMENT:
-- 1. This script assumes PostgreSQL; for SQL Server/T-SQL, adjust:
--    - SERIAL → IDENTITY(1,1)
--    - CURRENT_DATE → GETDATE()
--    - regexp_split_to_table() → STRING_SPLIT()
--    - INTERVAL → DATEADD()
-- 2. For production use, add:
--    - Incremental load logic (track last_updated timestamps)
--    - Data quality checks (null rate monitoring, outlier detection)
--    - Parameterized views or stored procedures for report automation
--    - Row-level security if deploying in Power BI
-- 3. Performance optimization opportunities:
--    - Materialized views for frequently-run aggregations
--    - Partitioning on studies.start_date for large datasets
--    - Additional indexes based on query execution plans
-- ============================================