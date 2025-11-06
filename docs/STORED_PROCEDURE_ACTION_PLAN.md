# Stored Procedure Migration - Action Plan

## Quick Reference: Procedure Inventory

### By Complexity & Priority

#### Priority 1: Simple SELECT Queries (Low Risk, Quick Wins)
1. `list_instances()` - Simple SELECT
2. `list_executions(p_instance_id)` - Simple SELECT with WHERE
3. `latest_execution_id(p_instance_id)` - Simple SELECT
4. `read(p_instance_id)` - SELECT with JOIN
5. `read_with_execution(p_instance_id, p_execution_id)` - SELECT with WHERE

#### Priority 2: JOIN Queries (Medium Complexity)
6. `get_instance_info(p_instance_id)` - JOIN instances + executions
7. `get_execution_info(p_instance_id, p_execution_id)` - JOIN executions + COUNT
8. `list_instances_by_status(p_status)` - JOIN with WHERE

#### Priority 3: Aggregate Queries (Medium Complexity)
9. `get_system_metrics()` - Multiple COUNT queries
10. `get_queue_depths(p_now_ms)` - COUNT with WHERE

#### Priority 4: Simple INSERT/UPDATE (Medium Risk)
11. `enqueue_worker_work(p_work_item, p_instance_id)` - INSERT
12. `append_history(...)` - Batch INSERT with ON CONFLICT
13. `enqueue_orchestrator_work(...)` - INSERT with instance creation

#### Priority 5: Complex Transactions (High Risk)
14. `fetch_orchestration_item(p_now_ms, p_lock_timeout_ms)` - Multi-step transaction
15. `ack_orchestration_item(...)` - Very large transaction (10+ operations)
16. `abandon_orchestration_item(p_lock_token, p_delay_ms)` - UPDATE + DELETE
17. `ack_worker(p_lock_token, p_completion)` - DELETE + INSERT
18. `dequeue_worker_peek_lock(p_now_ms, p_lock_timeout_ms)` - SELECT FOR UPDATE + UPDATE

#### Priority 6: Schema Management (Special Case)
19. `initialize_schema()` - DDL operations
20. `cleanup_schema()` - DDL operations

## Implementation Checklist

### Phase 1: Setup & Infrastructure
- [ ] Create migration file: `migrations/0002_create_stored_procedures.sql`
- [ ] Create helper function for schema-qualified procedure creation
- [ ] Add procedure version tracking (optional)
- [ ] Set up testing infrastructure for stored procedures

### Phase 2: Priority 1 - Simple SELECTs (Start Here)
- [ ] `sp_list_instances()` - Returns TABLE(instance_id TEXT)
- [ ] `sp_list_executions(p_instance_id TEXT)` - Returns TABLE(execution_id BIGINT)
- [ ] `sp_get_latest_execution_id(p_instance_id TEXT)` - Returns BIGINT
- [ ] Update Rust code for above 3 procedures
- [ ] Test and verify

### Phase 3: Priority 1 - Read Operations
- [ ] `sp_read_history(p_instance_id TEXT, p_execution_id BIGINT)` - Returns TABLE(event_data JSONB)
- [ ] `sp_read_current_history(p_instance_id TEXT)` - Returns TABLE(event_data JSONB)
- [ ] Update `read()` and `read_with_execution()` methods
- [ ] Test and verify

### Phase 4: Priority 2 - JOIN Queries
- [ ] `sp_get_instance_info(p_instance_id TEXT)` - Returns TABLE with instance+execution data
- [ ] `sp_get_execution_info(p_instance_id TEXT, p_execution_id BIGINT)` - Returns TABLE with execution+count
- [ ] `sp_list_instances_by_status(p_status TEXT)` - Returns TABLE(instance_id TEXT)
- [ ] Update Rust code
- [ ] Test and verify

### Phase 5: Priority 3 - Aggregate Queries
- [ ] `sp_get_system_metrics()` - Returns JSONB with all metrics
- [ ] `sp_get_queue_depths(p_now_ms BIGINT)` - Returns TABLE(orchestrator_queue BIGINT, worker_queue BIGINT)
- [ ] Update Rust code
- [ ] Test and verify

### Phase 6: Priority 4 - Simple Writes
- [ ] `sp_enqueue_worker_work(p_work_item TEXT)` - Returns BIGINT (id)
- [ ] `sp_append_history(p_instance_id TEXT, p_execution_id BIGINT, p_events JSONB)` - Batch insert
- [ ] `sp_enqueue_orchestrator_work(...)` - Complex INSERT with instance creation
- [ ] Update Rust code
- [ ] Test and verify

### Phase 7: Priority 5 - Queue Operations
- [ ] `sp_dequeue_worker_peek_lock(p_now_ms BIGINT, p_lock_timeout_ms BIGINT)` - Returns TABLE(id BIGINT, work_item TEXT, lock_token TEXT)
- [ ] `sp_ack_worker(p_lock_token TEXT, p_completion_json TEXT, p_instance_id TEXT)` - Transaction
- [ ] Update Rust code
- [ ] Test concurrency scenarios

### Phase 8: Priority 5 - Core Orchestration (Most Complex)
- [ ] `sp_fetch_orchestration_item(p_now_ms BIGINT, p_lock_timeout_ms BIGINT)` - Returns JSONB
- [ ] `sp_ack_orchestration_item(...)` - Very complex, consider breaking into sub-procedures
- [ ] `sp_abandon_orchestration_item(p_lock_token TEXT, p_delay_ms BIGINT)` - Transaction
- [ ] Update Rust code
- [ ] Extensive testing with concurrency

### Phase 9: Priority 6 - Schema Management
- [ ] `sp_create_schema(p_schema_name TEXT)` - DDL wrapper
- [ ] `sp_initialize_tables(p_schema_name TEXT)` - All CREATE TABLE statements
- [ ] `sp_create_indexes(p_schema_name TEXT)` - All CREATE INDEX statements
- [ ] Update `initialize_schema()` method
- [ ] Test schema creation/destruction

### Phase 10: Final Integration
- [ ] Update all remaining Rust code
- [ ] Remove old SQL strings
- [ ] Run full test suite
- [ ] Performance benchmarking
- [ ] Documentation updates

## Procedure Naming Convention

Format: `{schema}.sp_{operation}_{entity}`

Examples:
- `public.sp_list_instances()`
- `public.sp_get_instance_info(p_instance_id TEXT)`
- `public.sp_fetch_orchestration_item(p_now_ms BIGINT, p_lock_timeout_ms BIGINT)`

## Procedure Template

```sql
-- Example: Simple SELECT procedure
CREATE OR REPLACE FUNCTION {schema}.sp_list_instances()
RETURNS TABLE(instance_id TEXT) AS $$
BEGIN
    RETURN QUERY
    SELECT i.instance_id
    FROM {schema}.instances i
    ORDER BY i.created_at DESC;
END;
$$ LANGUAGE plpgsql;

-- Example: Procedure with parameters
CREATE OR REPLACE FUNCTION {schema}.sp_get_instance_info(
    p_instance_id TEXT
) RETURNS TABLE(
    instance_id TEXT,
    orchestration_name TEXT,
    orchestration_version TEXT,
    current_execution_id BIGINT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    status TEXT,
    output TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT i.instance_id, i.orchestration_name, i.orchestration_version,
           i.current_execution_id, i.created_at, i.updated_at,
           e.status, e.output
    FROM {schema}.instances i
    LEFT JOIN {schema}.executions e ON i.instance_id = e.instance_id 
      AND i.current_execution_id = e.execution_id
    WHERE i.instance_id = p_instance_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Instance not found: %', p_instance_id;
    END IF;
END;
$$ LANGUAGE plpgsql;
```

## Rust Code Update Pattern

### Before:
```rust
async fn list_instances(&self) -> Vec<String> {
    sqlx::query_scalar(&format!(
        "SELECT instance_id FROM {} ORDER BY created_at DESC",
        self.table_name("instances")
    ))
    .fetch_all(&*self.pool)
    .await
    .ok()
    .unwrap_or_default()
}
```

### After:
```rust
async fn list_instances(&self) -> Vec<String> {
    sqlx::query_scalar(&format!(
        "SELECT instance_id FROM {}.sp_list_instances()",
        self.schema_name
    ))
    .fetch_all(&*self.pool)
    .await
    .ok()
    .unwrap_or_default()
}
```

## Error Handling Pattern

### In Procedures:
```sql
-- Validation
IF p_instance_id IS NULL OR p_instance_id = '' THEN
    RAISE EXCEPTION 'Invalid instance_id';
END IF;

-- Not found
IF NOT FOUND THEN
    RAISE EXCEPTION 'Instance not found: %', p_instance_id;
END IF;

-- Use SQLSTATE for specific error codes
RAISE EXCEPTION USING 
    ERRCODE = '23505',  -- Unique violation
    MESSAGE = 'Duplicate event_id';
```

### In Rust:
```rust
.map_err(|e| {
    if e.as_database_error()
        .and_then(|e| e.code())
        .as_deref() == Some("23505")
    {
        format!("Duplicate event_id")
    } else {
        format!("Failed to ...: {}", e)
    }
})
```

## Testing Checklist Per Procedure

- [ ] Test with valid inputs
- [ ] Test with NULL inputs
- [ ] Test with invalid inputs
- [ ] Test with non-existent records
- [ ] Test error conditions
- [ ] Test return type matches Rust expectations
- [ ] Test performance (compare to inline SQL)
- [ ] Test with custom schema name
- [ ] Test concurrent access (if applicable)

## Migration Strategy

### Option A: Big Bang (Not Recommended)
- Convert all at once
- High risk, difficult to test

### Option B: Incremental (Recommended)
- Convert one procedure at a time
- Test after each conversion
- Lower risk, easier to debug

### Option C: Feature Flag (Safest)
- Add feature flag to switch between SQL and procedures
- Allows gradual rollout
- Can rollback per-method if needed

## Estimated Timeline

- **Phase 1-2**: 2-3 days (Simple SELECTs)
- **Phase 3-4**: 2-3 days (JOIN queries)
- **Phase 5**: 1-2 days (Aggregates)
- **Phase 6**: 2-3 days (Simple writes)
- **Phase 7**: 3-4 days (Queue operations)
- **Phase 8**: 5-7 days (Core orchestration - most complex)
- **Phase 9**: 2-3 days (Schema management)
- **Phase 10**: 3-5 days (Testing, integration, cleanup)

**Total**: ~3-4 weeks with careful testing

## Critical Considerations

1. **Schema Names**: All procedures must handle dynamic schema names
2. **Transactions**: Some procedures need to run in transactions, others create their own
3. **Return Types**: Match Rust expectations exactly
4. **Error Codes**: Preserve error codes for proper error handling
5. **Performance**: Monitor query plans, may need hints or optimizations
6. **Concurrency**: Test lock acquisition, especially for queue operations
7. **Backward Compatibility**: Ensure existing code continues to work during migration

## Risk Mitigation

1. **Keep old SQL as comments** during migration
2. **Feature flag** to switch between implementations
3. **Comprehensive testing** at each phase
4. **Performance benchmarks** before/after
5. **Gradual rollout** starting with low-risk procedures

