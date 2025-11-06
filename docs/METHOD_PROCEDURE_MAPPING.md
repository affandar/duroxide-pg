# Method to Stored Procedure Mapping

This document maps each Rust method to its corresponding stored procedure name and complexity.

## Provider Trait Implementation

| Method | Stored Procedure | Priority | Complexity | SQL Queries | Notes |
|--------|------------------|----------|------------|-------------|-------|
| `initialize_schema()` | `sp_initialize_schema()` | 6 | Medium | 9 | DDL operations |
| `cleanup_schema()` | `sp_cleanup_schema()` | 6 | Low | 7 | DDL operations |
| `fetch_orchestration_item()` | `sp_fetch_orchestration_item()` | 5 | Very High | 5 | Complex transaction, SELECT FOR UPDATE |
| `ack_orchestration_item()` | `sp_ack_orchestration_item()` | 5 | Very High | 10+ | Large transaction, many operations |
| `abandon_orchestration_item()` | `sp_abandon_orchestration_item()` | 5 | High | 3 | UPDATE + DELETE transaction |
| `read()` | `sp_read_current_history()` | 1 | Low | 2 | Simple SELECT |
| `read_with_execution()` | `sp_read_history()` | 1 | Low | 1 | Simple SELECT |
| `append_with_execution()` | `sp_append_history()` | 4 | Medium | 1 | Batch INSERT with ON CONFLICT |
| `enqueue_worker_work()` | `sp_enqueue_worker_work()` | 4 | Low | 1 | Simple INSERT |
| `dequeue_worker_peek_lock()` | `sp_dequeue_worker_peek_lock()` | 5 | High | 2 | SELECT FOR UPDATE + UPDATE |
| `ack_worker()` | `sp_ack_worker()` | 5 | High | 2 | DELETE + INSERT transaction |
| `enqueue_orchestrator_work()` | `sp_enqueue_orchestrator_work()` | 4 | Medium | 3 | INSERT with instance creation |
| `latest_execution_id()` | `sp_get_latest_execution_id()` | 1 | Low | 1 | Simple SELECT |
| `list_instances()` | `sp_list_instances()` | 1 | Low | 1 | Simple SELECT |
| `list_executions()` | `sp_list_executions()` | 1 | Low | 1 | Simple SELECT |

## ManagementCapability Trait Implementation

| Method | Stored Procedure | Priority | Complexity | SQL Queries | Notes |
|--------|------------------|----------|------------|-------------|-------|
| `list_instances()` | `sp_list_instances()` | 1 | Low | 1 | Same as Provider trait |
| `list_instances_by_status()` | `sp_list_instances_by_status()` | 2 | Medium | 1 | JOIN query |
| `list_executions()` | `sp_list_executions()` | 1 | Low | 1 | Same as Provider trait |
| `read_execution()` | `sp_read_execution()` | 1 | Low | 1 | Simple SELECT |
| `latest_execution_id()` | `sp_get_latest_execution_id()` | 1 | Low | 1 | Same as Provider trait |
| `get_instance_info()` | `sp_get_instance_info()` | 2 | Medium | 1 | JOIN query |
| `get_execution_info()` | `sp_get_execution_info()` | 2 | Medium | 2 | JOIN + COUNT |
| `get_system_metrics()` | `sp_get_system_metrics()` | 3 | Medium | 6 | Multiple aggregate queries |
| `get_queue_depths()` | `sp_get_queue_depths()` | 3 | Medium | 2 | COUNT queries |

## Detailed Procedure Signatures

### Priority 1: Simple SELECT Queries

```sql
-- sp_list_instances()
RETURNS TABLE(instance_id TEXT)

-- sp_list_executions(p_instance_id TEXT)
RETURNS TABLE(execution_id BIGINT)

-- sp_get_latest_execution_id(p_instance_id TEXT)
RETURNS BIGINT

-- sp_read_current_history(p_instance_id TEXT)
RETURNS TABLE(event_data TEXT)

-- sp_read_history(p_instance_id TEXT, p_execution_id BIGINT)
RETURNS TABLE(event_data TEXT)

-- sp_read_execution(p_instance_id TEXT, p_execution_id BIGINT)
RETURNS TABLE(event_data TEXT)
```

### Priority 2: JOIN Queries

```sql
-- sp_get_instance_info(p_instance_id TEXT)
RETURNS TABLE(
    instance_id TEXT,
    orchestration_name TEXT,
    orchestration_version TEXT,
    current_execution_id BIGINT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    status TEXT,
    output TEXT
)

-- sp_list_instances_by_status(p_status TEXT)
RETURNS TABLE(instance_id TEXT)

-- sp_get_execution_info(p_instance_id TEXT, p_execution_id BIGINT)
RETURNS TABLE(
    execution_id BIGINT,
    status TEXT,
    output TEXT,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    event_count BIGINT
)
```

### Priority 3: Aggregate Queries

```sql
-- sp_get_system_metrics()
RETURNS TABLE(
    total_instances BIGINT,
    total_executions BIGINT,
    running_instances BIGINT,
    completed_instances BIGINT,
    failed_instances BIGINT,
    total_events BIGINT
)

-- sp_get_queue_depths(p_now_ms BIGINT)
RETURNS TABLE(
    orchestrator_queue BIGINT,
    worker_queue BIGINT
)
```

### Priority 4: Simple Writes

```sql
-- sp_enqueue_worker_work(p_work_item TEXT)
RETURNS BIGINT  -- Returns inserted id

-- sp_append_history(
--     p_instance_id TEXT,
--     p_execution_id BIGINT,
--     p_events JSONB  -- Array of {event_id, event_type, event_data}
-- )
RETURNS VOID

-- sp_enqueue_orchestrator_work(
--     p_instance_id TEXT,
--     p_work_item TEXT,
--     p_visible_at TIMESTAMPTZ,
--     p_orchestration_name TEXT DEFAULT NULL,
--     p_orchestration_version TEXT DEFAULT NULL,
--     p_execution_id BIGINT DEFAULT NULL
-- )
RETURNS VOID
```

### Priority 5: Complex Operations

```sql
-- sp_fetch_orchestration_item(
--     p_now_ms BIGINT,
--     p_lock_timeout_ms BIGINT
-- )
RETURNS TABLE(
    instance_id TEXT,
    orchestration_name TEXT,
    orchestration_version TEXT,
    execution_id BIGINT,
    history JSONB,
    messages JSONB,
    lock_token TEXT
)

-- sp_ack_orchestration_item(
--     p_lock_token TEXT,
--     p_execution_id BIGINT,
--     p_history_delta JSONB,
--     p_worker_items JSONB,
--     p_orchestrator_items JSONB,
--     p_metadata JSONB
-- )
RETURNS VOID

-- sp_abandon_orchestration_item(
--     p_lock_token TEXT,
--     p_delay_ms BIGINT DEFAULT NULL
-- )
RETURNS VOID

-- sp_dequeue_worker_peek_lock(
--     p_now_ms BIGINT,
--     p_lock_timeout_ms BIGINT
-- )
RETURNS TABLE(
    id BIGINT,
    work_item TEXT,
    lock_token TEXT
)

-- sp_ack_worker(
--     p_lock_token TEXT,
--     p_completion_json TEXT,
--     p_instance_id TEXT
-- )
RETURNS VOID
```

### Priority 6: Schema Management

```sql
-- sp_initialize_schema()
RETURNS VOID
-- Creates all tables and indexes

-- sp_cleanup_schema()
RETURNS VOID
-- Drops all tables (and schema if custom)
```

## Migration Order (Recommended)

### Week 1: Simple Queries
1. `sp_list_instances()`
2. `sp_list_executions()`
3. `sp_get_latest_execution_id()`
4. `sp_read_current_history()`
5. `sp_read_history()`
6. `sp_read_execution()`

### Week 2: JOIN and Aggregate Queries
7. `sp_get_instance_info()`
8. `sp_list_instances_by_status()`
9. `sp_get_execution_info()`
10. `sp_get_system_metrics()`
11. `sp_get_queue_depths()`

### Week 3: Simple Writes
12. `sp_enqueue_worker_work()`
13. `sp_append_history()`
14. `sp_enqueue_orchestrator_work()`

### Week 4: Complex Operations
15. `sp_dequeue_worker_peek_lock()`
16. `sp_ack_worker()`
17. `sp_abandon_orchestration_item()`
18. `sp_fetch_orchestration_item()` ⚠️ Most complex
19. `sp_ack_orchestration_item()` ⚠️ Very complex

### Week 5: Schema Management
20. `sp_initialize_schema()`
21. `sp_cleanup_schema()`

## Notes

- Procedures with the same name serve multiple Rust methods (they're identical)
- Some procedures return JSONB for complex data structures
- Transaction boundaries are handled within procedures for complex operations
- Schema name is passed as part of the procedure name: `{schema}.sp_{name}()`

