# Stored Procedure Migration Plan

## Overview

This document outlines the plan to convert all SQL queries in `src/provider.rs` from inline SQL to PostgreSQL stored procedures (functions). This migration will improve maintainability, performance, and database encapsulation.

## Current State Analysis

### Statistics
- **Total SQL queries**: ~70 queries across 27 methods
- **Database**: PostgreSQL (using `sqlx` crate)
- **Schema support**: Dynamic schema names (default: "public")
- **Transaction usage**: Multiple methods use transactions

### Query Categories

#### 1. Schema Management (9 queries)
- `initialize_schema()`: CREATE TABLE, CREATE INDEX, ALTER TABLE
- `cleanup_schema()`: DROP TABLE, DROP SCHEMA

#### 2. Core Provider Operations (25+ queries)
- `fetch_orchestration_item()`: Complex multi-step transaction with SELECT FOR UPDATE SKIP LOCKED
- `ack_orchestration_item()`: Large transaction with multiple INSERT/UPDATE/DELETE operations
- `abandon_orchestration_item()`: UPDATE + DELETE operations
- `read()` / `read_with_execution()`: SELECT queries
- `append_with_execution()`: INSERT with ON CONFLICT

#### 3. Queue Operations (10+ queries)
- `enqueue_worker_work()`, `dequeue_worker_peek_lock()`, `ack_worker()`: Worker queue operations
- `enqueue_orchestrator_work()`: Orchestrator queue operations

#### 4. Management Capability Operations (15+ queries)
- `list_instances()`, `list_executions()`, `read_execution()`: Simple SELECT queries
- `get_instance_info()`, `get_execution_info()`: JOIN queries
- `get_system_metrics()`, `get_queue_depths()`: Aggregate queries

## Migration Strategy

### Phase 1: Design & Planning

#### 1.1 Stored Procedure Naming Convention
- Format: `{schema}.{operation}_{entity}[_{action}]`
- Examples:
  - `public.fetch_orchestration_item()`
  - `public.ack_orchestration_item()`
  - `public.get_instance_info(p_instance_id TEXT)`
  - `public.enqueue_worker_work(p_work_item TEXT)`

#### 1.2 Schema Handling Strategy
Since the provider supports dynamic schema names, we have two options:

**Option A: Schema-qualified procedures** (Recommended)
- Create procedures in the target schema
- Use `SET search_path` or fully qualified names
- Pros: Schema isolation, clearer ownership
- Cons: Requires schema creation for each custom schema

**Option B: Search path-based**
- Create procedures in a shared schema, use `search_path`
- Pros: Single copy of procedures
- Cons: Less isolation, potential conflicts

**Decision: Option A** - Create procedures per schema for proper isolation

#### 1.3 Procedure Organization

Group procedures by functionality:

1. **Schema Management**
   - `create_schema()` - Create schema if needed
   - `drop_schema()` - Cleanup (testing only)

2. **Orchestration Operations**
   - `fetch_orchestration_item(p_now_ms BIGINT, p_lock_timeout_ms BIGINT)`
   - `ack_orchestration_item(...)` - Complex, needs careful parameter design
   - `abandon_orchestration_item(p_lock_token TEXT, p_delay_ms BIGINT)`

3. **History Operations**
   - `read_history(p_instance_id TEXT, p_execution_id BIGINT)`
   - `append_history(...)` - Batch insert

4. **Queue Operations**
   - `enqueue_worker_work(p_work_item TEXT)`
   - `dequeue_worker_peek_lock(p_now_ms BIGINT, p_lock_timeout_ms BIGINT)`
   - `ack_worker(p_lock_token TEXT, p_completion_json TEXT, p_instance_id TEXT)`
   - `enqueue_orchestrator_work(...)`

5. **Management Operations**
   - `list_instances()`
   - `list_executions(p_instance_id TEXT)`
   - `get_instance_info(p_instance_id TEXT)`
   - `get_execution_info(p_instance_id TEXT, p_execution_id BIGINT)`
   - `get_system_metrics()`
   - `get_queue_depths(p_now_ms BIGINT)`

### Phase 2: Implementation Approach

#### 2.1 Migration File Structure

```
migrations/
  0001_initial_schema.sql          # Existing
  0002_create_stored_procedures.sql # New: Create all procedures
```

#### 2.2 Procedure Creation Strategy

**For schema-qualified procedures:**
- Create procedures in a function that takes schema name as parameter
- Use dynamic SQL execution during initialization
- Store procedure names in a helper map

**Alternative: Migration Script**
- Create a migration script that generates procedures for each schema
- Use `EXECUTE format()` to create schema-qualified procedures

#### 2.3 Complex Procedures - Special Considerations

**`fetch_orchestration_item`:**
- Multi-step transaction with SELECT FOR UPDATE SKIP LOCKED
- Returns multiple values (instance_id, orchestration_name, execution_id, history, messages)
- Use `RETURNS TABLE` or composite type
- Consider returning JSON for complex data structures

**`ack_orchestration_item`:**
- Very large transaction (~10+ operations)
- Needs to return early on validation failures
- Use exception handling with `RAISE EXCEPTION`
- Consider breaking into smaller procedures if needed

**`get_instance_info` / `get_execution_info`:**
- JOIN queries returning structured data
- Use `RETURNS TABLE` with typed columns

#### 2.4 Parameter Naming Convention

- Prefix parameters with `p_` to avoid conflicts with column names
- Examples: `p_instance_id`, `p_execution_id`, `p_lock_token`

#### 2.5 Return Types

- Single values: Use `RETURNS TYPE`
- Multiple rows: Use `RETURNS TABLE(...)`
- Complex data: Use `RETURNS JSON` or `RETURNS JSONB`
- Errors: Use `RAISE EXCEPTION` with error codes

### Phase 3: Code Changes

#### 3.1 Provider Implementation Updates

**Before:**
```rust
sqlx::query(&format!(
    "SELECT instance_id FROM {} WHERE instance_id = $1",
    self.table_name("instances")
))
.bind(instance)
.fetch_optional(&*self.pool)
```

**After:**
```rust
sqlx::query(&format!("SELECT * FROM {}.get_instance_info($1)", self.schema_name))
.bind(instance)
.fetch_optional(&*self.pool)
```

#### 3.2 Error Handling

- Map PostgreSQL exceptions to Rust errors
- Preserve error messages and codes
- Handle transaction rollbacks appropriately

#### 3.3 Transaction Management

- Most procedures will handle their own transactions
- For procedures that need to be called within a transaction:
  - Use `SET LOCAL` for transaction-scoped settings
  - Document transaction requirements clearly

### Phase 4: Migration Script

#### 4.1 Create Migration File

Create `migrations/0002_create_stored_procedures.sql` with:

1. Helper function to create schema-qualified procedures
2. All procedure definitions
3. Version tracking table (optional)

#### 4.2 Procedure Template

```sql
CREATE OR REPLACE FUNCTION {schema}.procedure_name(
    p_param1 TYPE,
    p_param2 TYPE
) RETURNS TABLE(...) AS $$
BEGIN
    -- Procedure body
END;
$$ LANGUAGE plpgsql;
```

#### 4.3 Schema Qualification

Use a function like:
```sql
CREATE OR REPLACE FUNCTION create_procedures_in_schema(p_schema_name TEXT) 
RETURNS VOID AS $$
BEGIN
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', p_schema_name);
    -- Create each procedure in the schema
END;
$$ LANGUAGE plpgsql;
```

## Implementation Phases

### Phase 1: Preparation (Week 1)
- [ ] Review and categorize all SQL queries
- [ ] Design procedure signatures
- [ ] Create procedure dependency graph
- [ ] Review transaction boundaries
- [ ] Design error handling strategy

### Phase 2: Schema Management Procedures (Week 1)
- [ ] Create `initialize_schema` procedure
- [ ] Create `cleanup_schema` procedure
- [ ] Test schema creation/destruction

### Phase 3: Simple Query Procedures (Week 2)
- [ ] Convert simple SELECT queries
  - `list_instances()`
  - `list_executions()`
  - `read()` / `read_with_execution()`
  - `latest_execution_id()`
- [ ] Update Rust code to call procedures
- [ ] Test each procedure individually

### Phase 4: Complex Query Procedures (Week 2-3)
- [ ] Convert JOIN queries
  - `get_instance_info()`
  - `get_execution_info()`
  - `list_instances_by_status()`
- [ ] Convert aggregate queries
  - `get_system_metrics()`
  - `get_queue_depths()`
- [ ] Test with various data scenarios

### Phase 5: Queue Operations (Week 3)
- [ ] Convert worker queue procedures
  - `enqueue_worker_work()`
  - `dequeue_worker_peek_lock()`
  - `ack_worker()`
- [ ] Convert orchestrator queue procedures
  - `enqueue_orchestrator_work()`
- [ ] Test concurrency scenarios

### Phase 6: Core Orchestration Procedures (Week 4)
- [ ] Convert `fetch_orchestration_item()` (complex)
- [ ] Convert `ack_orchestration_item()` (very complex)
- [ ] Convert `abandon_orchestration_item()`
- [ ] Test transaction isolation
- [ ] Test lock acquisition/expiration

### Phase 7: History Operations (Week 4)
- [ ] Convert `append_with_execution()`
- [ ] Optimize batch inserts
- [ ] Test duplicate detection

### Phase 8: Integration & Testing (Week 5)
- [ ] Update all Rust code to use procedures
- [ ] Run full test suite
- [ ] Performance benchmarking
- [ ] Load testing

### Phase 9: Documentation & Cleanup (Week 5)
- [ ] Document all procedures
- [ ] Update API documentation
- [ ] Remove old SQL strings
- [ ] Code review

## Detailed Procedure Design

### 1. `fetch_orchestration_item`

**Signature:**
```sql
CREATE OR REPLACE FUNCTION {schema}.fetch_orchestration_item(
    p_now_ms BIGINT,
    p_lock_timeout_ms BIGINT,
    p_schema_name TEXT DEFAULT 'public'
) RETURNS TABLE(
    instance_id TEXT,
    orchestration_name TEXT,
    orchestration_version TEXT,
    execution_id BIGINT,
    history JSONB,
    messages JSONB,
    lock_token TEXT
) AS $$
DECLARE
    v_instance_id TEXT;
    v_lock_token TEXT;
    v_locked_until BIGINT;
BEGIN
    -- Step 1: Find available instance
    -- Step 2: Acquire lock
    -- Step 3: Lock messages
    -- Step 4: Fetch messages
    -- Step 5: Load instance metadata and history
    -- Return results
END;
$$ LANGUAGE plpgsql;
```

### 2. `ack_orchestration_item`

**Signature:**
```sql
CREATE OR REPLACE FUNCTION {schema}.ack_orchestration_item(
    p_lock_token TEXT,
    p_execution_id BIGINT,
    p_instance_id TEXT,
    p_history_delta JSONB,
    p_worker_items JSONB,
    p_orchestrator_items JSONB,
    p_metadata JSONB,
    p_schema_name TEXT DEFAULT 'public'
) RETURNS VOID AS $$
BEGIN
    -- Validate lock
    -- Create execution
    -- Update instance
    -- Append history
    -- Update execution metadata
    -- Enqueue worker items
    -- Enqueue orchestrator items
    -- Delete locked messages
    -- Remove instance lock
END;
$$ LANGUAGE plpgsql;
```

### 3. `get_instance_info`

**Signature:**
```sql
CREATE OR REPLACE FUNCTION {schema}.get_instance_info(
    p_instance_id TEXT,
    p_schema_name TEXT DEFAULT 'public'
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
END;
$$ LANGUAGE plpgsql;
```

## Testing Strategy

### Unit Tests
- Test each procedure independently
- Test with various input scenarios
- Test error conditions
- Test edge cases (empty results, NULL values)

### Integration Tests
- Test provider methods end-to-end
- Test transaction rollbacks
- Test concurrent access
- Test schema isolation

### Performance Tests
- Compare performance before/after
- Test under load
- Monitor query plans
- Check for N+1 query issues

### Regression Tests
- Run full test suite
- Test with existing data
- Test migration path

## Rollback Plan

### If Issues Arise

1. **Feature Flag Approach**
   - Add feature flag to switch between inline SQL and stored procedures
   - Allows gradual rollout
   - Easy rollback

2. **Keep Inline SQL**
   - Keep original SQL as comments
   - Allows quick revert if needed

3. **Migration Rollback**
   - Create migration to drop procedures
   - Revert code changes
   - Test rollback procedure

## Benefits

1. **Performance**
   - Compiled query plans
   - Reduced network round trips
   - Database-level optimizations

2. **Maintainability**
   - Centralized SQL logic
   - Easier to update queries
   - Version control for SQL

3. **Security**
   - Parameterized queries enforced
   - Reduced SQL injection risk
   - Better access control

4. **Consistency**
   - Single source of truth for queries
   - Consistent error handling
   - Standardized behavior

## Risks & Mitigation

### Risk 1: Schema Name Handling
- **Mitigation**: Careful testing with custom schemas
- **Mitigation**: Schema-qualified procedure creation

### Risk 2: Transaction Isolation
- **Mitigation**: Careful transaction boundary design
- **Mitigation**: Extensive testing

### Risk 3: Performance Regression
- **Mitigation**: Benchmark before/after
- **Mitigation**: Review query plans

### Risk 4: Error Handling Complexity
- **Mitigation**: Standardize error codes
- **Mitigation**: Comprehensive error mapping

## Next Steps

1. Review and approve this plan
2. Create initial migration file structure
3. Start with Phase 1 (simple procedures)
4. Incrementally migrate complex procedures
5. Continuous testing throughout

## Notes

- Consider using `RETURNS SETOF` for multi-row results
- Use `SECURITY DEFINER` if needed for access control
- Consider caching frequently called procedures
- Document all procedures with comments
- Use consistent error codes/messages

