# Real-Time AdTech & Clickstream Analytics on Vertica MPP

Промышленный проект, демонстрирующий глубокую экспертизу работы с колоночной MPP-СУБД **OpenText Vertica** на задаче высоконагруженной аналитики рекламных кликов и воронки конверсий (*AdTech Clickstream & Attribution*).

## 1. Архитектура решения и ключевые фичи Vertica

В отличие от классических строковых СУБД, Vertica не использует B-Tree индексы. Производительность достигается за счёт правильного проектирования **проекций (Projections)**, **кодирования сжатия (Encoding)** и **алгоритмов сегментации**:

1. **Проектирование Суперпроекций и Специальных Проекций (`CREATE PROJECTION`):**
   * `superprojection` оптимизирована под временные ряды (`ORDER BY event_ts, campaign_id`) и равномерно распределена по кластеру (`SEGMENTED BY HASH(user_id) ALL NODES`).
   * **Pre-Join / Query-Specific Projection:** отдельная проекция, отсортированная по `campaign_id, country_code, event_ts`, позволяющая выполнять тяжёлые BI-агрегации без сетевого перераспределения данных (`RESEGMENT`).
2. **Продвинутое колоночное сжатие (`ENCODING`):**
   * `DELTARANGE_COMP` для монотонно возрастающих временных меток (`event_ts`).
   * `RLE` (Run-Length Encoding) для низкокардинальных столбцов (`event_type`, `device_type`, `country_code`) — сжимает повторяющиеся значения в десятки раз и позволяет выполнять агрегации прямо поверх сжатых блоков без распаковки.
   * `ZSTD_FAST_COMP` для высококардинальных строковых идентификаторов (`click_id`, `url_path`).
3. **Иерархическое партиционирование и управление хранением (`PARTITION BY`):**
   * Партиционирование по дням (`event_ts::DATE`) с автоматической группировкой старых партиций (`GROUP BY calendar_hierarchy_day(event_ts::DATE, 3, 2)`), что предотвращает проблему *ROS Pushback* (слишком большого количества мелких ROS-контейнеров).
4. **Нативные аналитические функции Vertica:**
   * **Sessionization (`CONDITIONAL_TRUE_EVENT`)**: нарезка кликстрима на пользовательские сессии с 30-минутным окном неактивности в один проход без `SELF JOIN`.
   * **Атрибуция конверсий (`LAST_VALUE(... IGNORE NULLS)`)**: связывание покупки с последним рекламным кликом пользователя (`Last-Click Attribution`).
   * **Приближённые подсчёты (`APPROXIMATE_COUNT_DISTINCT`)**: мгновенный расчёт уникальных охватов (Reach) по миллиардам событий на базе алгоритма HyperLogLog.
5. **Операции обслуживания (`Tuple Mover` & `Database Designer`):**
   * Контроль соотношения WOS/ROS контейнеров (`STORAGE_CONTAINERS`), принудительный `DO_TM_TASK('mergeout')` и удаление устаревших данных через `DROP_PARTITIONS`.

---

## 2. Структура репозитория

```text
adtech-clickstream-vertica-dwh/
├── README.md                          # Архитектура, обоснование проекций и инструкция запуска
├── docker-compose.yml                 # Локальный кластер Vertica Community Edition
├── 01_ddl_projections_encoding.sql    # Таблицы, суперпроекции, RLE/Delta сжатие и иерархические партиции
├── 02_etl_copy_and_maintenance.sql    # Загрузка через COPY DIRECT, генерация потока и управление ROS/WOS
└── 03_sessionization_attribution.sql  # Sessionization, Last-Click атрибуция, HyperLogLog и EXPLAIN план
```

---

## 3. Быстрый старт (Docker)

1. Запустите локальный узел Vertica:
   ```bash
   docker-compose up -d
   ```
   *(Дождитесь инициализации БД — обычно 30–60 секунд, пока в логах не появится `Vertica is now running`)*

2. Примените DDL со схемами, проекциями и правилами сжатия:
   ```bash
   docker exec -i vertica_dwh /opt/vertica/bin/vsql -U dbadmin -d VMart < 01_ddl_projections_encoding.sql
   ```

3. Загрузите синтетический батч событий (1 000 000 кликов и показов) и запустите обслуживание Tuple Mover:
   ```bash
   docker exec -i vertica_dwh /opt/vertica/bin/vsql -U dbadmin -d VMart < 02_etl_copy_and_maintenance.sql
   ```

4. Выполните аналитические запросы (сессионизация, атрибуция конверсий, анализ планов выполнения):
   ```bash
   docker exec -i vertica_dwh /opt/vertica/bin/vsql -U dbadmin -d VMart < 03_sessionization_attribution.sql
   ```
