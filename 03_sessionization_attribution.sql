-- ============================================================================
-- 03_sessionization_attribution.sql
-- Продвинутая аналитика: Sessionization, Last-Click Attribution и HyperLogLog
-- ============================================================================

-- 1. Нарезка пользовательских сессий (Sessionization) с помощью CONDITIONAL_TRUE_EVENT
-- Нативная функция Vertica: новая сессия начинается, если перерыв между событиями > 30 минут.
-- Благодаря сортировке проекции (ORDER BY user_id, event_ts) выполняется потоково без пересортировки!
WITH user_sessions AS (
    SELECT 
        user_id,
        event_ts,
        campaign_id,
        event_type,
        revenue_usd,
        CONDITIONAL_TRUE_EVENT(
            event_ts - LAG(event_ts) OVER (PARTITION BY user_id ORDER BY event_ts) > INTERVAL '30 minutes'
        ) OVER (PARTITION BY user_id ORDER BY event_ts) AS session_num
    FROM adtech.fct_ad_events
    WHERE event_ts >= TIMESTAMP '2026-11-01 00:00:00'
      AND event_ts <  TIMESTAMP '2026-11-03 00:00:00'
)
SELECT 
    user_id,
    session_num,
    MIN(event_ts) AS session_start,
    MAX(event_ts) AS session_end,
    EXTRACT(EPOCH FROM (MAX(event_ts) - MIN(event_ts))) AS session_duration_sec,
    COUNT(*) AS events_in_session,
    SUM(revenue_usd) AS session_revenue_usd
FROM user_sessions
GROUP BY user_id, session_num
HAVING SUM(revenue_usd) > 0
ORDER BY session_revenue_usd DESC
LIMIT 20;

-- 2. Атрибуция конверсий по последнему клику (Last-Click Attribution) через LAST_VALUE(... IGNORE NULLS)
WITH attributed_events AS (
    SELECT 
        user_id,
        event_ts,
        event_type,
        revenue_usd,
        -- Протягиваем campaign_id последнего клика до момента конверсии
        LAST_VALUE(CASE WHEN event_type = 'click' THEN campaign_id END IGNORE NULLS) 
            OVER (PARTITION BY user_id ORDER BY event_ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS attributed_campaign_id,
        LAST_VALUE(CASE WHEN event_type = 'click' THEN event_ts END IGNORE NULLS) 
            OVER (PARTITION BY user_id ORDER BY event_ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS last_click_ts
    FROM adtech.fct_ad_events
)
SELECT 
    c.vertical,
    a.attributed_campaign_id AS campaign_id,
    COUNT(*) AS attributed_conversions,
    SUM(a.revenue_usd) AS total_attributed_revenue_usd,
    ROUND(AVG(EXTRACT(EPOCH FROM (a.event_ts - a.last_click_ts)) / 60.0), 1) AS avg_time_to_convert_min
FROM attributed_events a
INNER JOIN adtech.dim_campaigns c ON a.attributed_campaign_id = c.campaign_id
WHERE a.event_type = 'conversion'
  AND a.attributed_campaign_id IS NOT NULL
  AND (a.event_ts - a.last_click_ts) <= INTERVAL '24 hours' -- Окно атрибуции 24 часа
GROUP BY c.vertical, a.attributed_campaign_id
ORDER BY total_attributed_revenue_usd DESC
LIMIT 15;

-- 3. Сравнение скорости и точности точного COUNT(DISTINCT) и приближённого HyperLogLog (APPROXIMATE_COUNT_DISTINCT)
SELECT 
    country_code,
    COUNT(*) AS total_events,
    COUNT(DISTINCT user_id) AS exact_unique_users,
    APPROXIMATE_COUNT_DISTINCT(user_id) AS hll_approx_unique_users,
    ROUND(ABS(COUNT(DISTINCT user_id) - APPROXIMATE_COUNT_DISTINCT(user_id))::NUMERIC / NULLIF(COUNT(DISTINCT user_id), 0) * 100, 3) AS error_pct
FROM adtech.fct_ad_events
GROUP BY country_code
ORDER BY total_events DESC;

-- 4. Проверка плана выполнения (EXPLAIN): подтверждение использования Live Aggregate Projection и отсутствия RESEGMENT
EXPLAIN
SELECT 
    campaign_id,
    DATE_TRUNC('hour', event_ts) AS event_hour,
    country_code,
    SUM(CASE WHEN event_type = 'click' THEN 1 ELSE 0 END) AS clicks,
    SUM(bid_price_usd) AS spend
FROM adtech.fct_ad_events
GROUP BY campaign_id, DATE_TRUNC('hour', event_ts), country_code;
