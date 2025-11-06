# Implementation Plan: PostgreSQL Provider for Duroxide

## Overview
Implement a PostgreSQL-based provider for Duroxide following the provider implementation guide. This provider will be production-ready with full ACID guarantees, better concurrency than SQLite, and support for distributed deployments.

## Key Requirements from Documentation

### Critical Principles
1. **No ID Generation**: Provider MUST NOT generate `execution_id` or `event_id` - runtime provides all IDs
2. **Atomicity**: All operations in `ack_orchestration_item()` must be in a single transaction
3. **Instance-Level Locking**: Prevent concurrent dispatchers from processing the same instance
4. **No Event Inspection**: Provider should NOT inspect event contents, use `ExecutionMetadata` instead
5. **Idempotency**: All operations must be idempotent (INSERT ... ON CONFLICT DO NOTHING pattern)

### Required Tables
All tables are created in the specified schema (default: "public"):
1. **instances** - Instance metadata (orchestration_name, version, current_execution_id)
2. **executions** - Execution tracking (status, output, timestamps)
3. **history** - Append-only event log (PRIMARY KEY: instance_id, execution_id, event_id)
4. **orchestrator_queue** - Orchestration work items (with visible_at for delayed timers)
5. **worker_queue** - Activity execution requests
6. **instance_locks** - ⚠️ CRITICAL: Instance-level locking table

**Note**: All table references use schema-qualified names: `schema_name.table_name`

### Required Indexes (Performance Critical)
- `orchestrator_queue`: (visible_at, lock_token), (instance_id), (lock_token)
- `worker_queue`: (lock_token, id)
- `history`: (instance_id, execution_id, event_id)
- `instance_locks`: (locked_until) for lock expiration checks

## Implementation Phases

### Phase 1: Schema & Infrastructure
**Goal**: Set up database schema and helper utilities

- [ ] Update `PostgresProvider` struct to store schema name
  - Add `schema_name: String` field (defaults to "public")
  - Update `new()` method to accept optional `schema_name` parameter
  - If schema_name provided, create schema if it doesn't exist (`CREATE SCHEMA IF NOT EXISTS schema_name`)
  - If not specified, use default "public" schema

- [ ] Create PostgreSQL migration file (`migrations/0001_initial_schema.sql`)
  - Convert SQLite schema to PostgreSQL (TEXT → VARCHAR/TEXT, INTEGER → BIGINT, TIMESTAMP → TIMESTAMPTZ)
  - Add all required indexes
  - Use PostgreSQL-specific features (e.g., SERIAL for auto-increment)
  - Use schema-qualified table names: `schema_name.table_name`
  - Support schema parameter in migration (use `CREATE SCHEMA IF NOT EXISTS` before tables)
  
- [ ] Implement `initialize_schema()` method
  - Create schema if it doesn't exist (`CREATE SCHEMA IF NOT EXISTS schema_name`)
  - Set search_path to schema (`SET search_path TO schema_name`)
  - Execute migration or create schema directly
  - Handle both migration-based and direct schema creation (for tests)
  - Ensure all table creation uses schema-qualified names
  
- [ ] Add helper methods:
  - `generate_lock_token()` - UUID-based lock tokens
  - `now_millis()` - Current timestamp in milliseconds (Unix epoch)
  - `timestamp_after_ms()` - Future timestamp calculator
  - `table_name()` - Helper to return schema-qualified table name (e.g., `"schema.instances"`)

### Phase 2: Core Orchestration Methods
**Goal**: Implement the three critical orchestration methods

#### 2.1 `fetch_orchestration_item()`
**Pattern**: PostgreSQL `SELECT FOR UPDATE SKIP LOCKED`

**Steps**:
1. Find available instance (atomic lock acquisition using `SELECT FOR UPDATE SKIP LOCKED`)
2. Atomically acquire instance lock (`INSERT ... ON CONFLICT DO UPDATE`)
3. Lock all messages for that instance (`UPDATE orchestrator_queue SET lock_token = ?`)
4. Load instance metadata (`SELECT FROM instances`)
5. Load history for current execution_id (`SELECT FROM history ORDER BY event_id`)
6. Fetch locked messages (`SELECT FROM orchestrator_queue WHERE lock_token = ?`)
7. Return `OrchestrationItem` with lock_token

**Key Points**:
- Use PostgreSQL `SELECT FOR UPDATE SKIP LOCKED` for atomic lock acquisition
- Validate lock acquisition with `rows_affected` check
- Handle missing instance metadata (derive from messages or history)
- Lock expires after `lock_timeout_ms` (30 seconds)

#### 2.2 `ack_orchestration_item()`
**Pattern**: Single PostgreSQL transaction

**Transaction Steps** (ALL must succeed or rollback):
1. Validate lock token (check `instance_locks` table, ensure not expired)
2. Remove instance lock (`DELETE FROM instance_locks WHERE lock_token = ?`)
3. Idempotently create execution row (`INSERT ... ON CONFLICT DO NOTHING`)
4. Update `instances.current_execution_id = MAX(current_execution_id, execution_id)`
5. Append `history_delta` events (validate `event_id > 0`, use `ON CONFLICT DO NOTHING`)
6. Update execution metadata (status, output) from `ExecutionMetadata`
7. Enqueue `worker_items` to worker queue
8. Enqueue `orchestrator_items` to orchestrator queue (handle `TimerFired` with `visible_at` delay)
9. Delete locked messages from orchestrator queue

**Key Points**:
- Use `sqlx::Transaction` for single transaction
- Validate all `event_id > 0` before inserting
- Handle `StartOrchestration` items (create instance + execution)
- Extract instance ID from `WorkItem` enum variants
- Set `visible_at = NOW() + delay_ms` for delayed items

#### 2.3 `abandon_orchestration_item()`
**Pattern**: Release lock, optionally delay visibility

**Steps**:
1. Validate lock token
2. Clear lock_token from messages (`UPDATE orchestrator_queue SET lock_token = NULL`)
3. Optionally update `visible_at` if delay_ms provided
4. Remove instance lock (`DELETE FROM instance_locks`)

### Phase 3: History Access Methods
**Goal**: Implement history read and append operations

- [ ] `read()` - Load latest execution history
  - Query `MAX(execution_id)` for instance
  - Load events ordered by `event_id`
  - Return empty `Vec<Event>` if instance doesn't exist

- [ ] `append_with_execution()` - Append events for specific execution
  - Validate `event_id > 0` for all events
  - Use `INSERT ... ON CONFLICT DO NOTHING` for idempotency
  - Extract `event_type` for indexing (discriminant name)

- [ ] `read_with_execution()` - Read specific execution history
  - Override default implementation for efficiency
  - Filter by both `instance_id` and `execution_id`

### Phase 4: Worker Queue Methods
**Goal**: Implement peek-lock semantics for worker queue

- [ ] `enqueue_worker_work()` - Simple insert with `lock_token = NULL`

- [ ] `dequeue_worker_peek_lock()` - Atomic lock acquisition
  ```sql
  SELECT id, work_item FROM schema_name.worker_queue
  WHERE lock_token IS NULL OR locked_until <= NOW()
  ORDER BY id
  LIMIT 1
  FOR UPDATE SKIP LOCKED;
  
  UPDATE schema_name.worker_queue
  SET lock_token = ?, locked_until = ?
  WHERE id = ?;
  ```

- [ ] `ack_worker()` - Atomic delete + enqueue completion
  ```sql
  BEGIN;
  DELETE FROM schema_name.worker_queue WHERE lock_token = ?;
  INSERT INTO schema_name.orchestrator_queue (instance_id, work_item, visible_at)
  VALUES (?, ?, NOW());
  COMMIT;
  ```

### Phase 5: Orchestrator Queue Methods
**Goal**: Implement orchestrator work enqueue with delay support

- [ ] `enqueue_orchestrator_work()` - Enqueue with optional delay
  - Extract instance ID from `WorkItem` enum
  - Handle `StartOrchestration` (create instance + execution)
  - Set `visible_at = NOW() + delay_ms` for delayed items
  - Use `NOW()` for immediate items

### Phase 6: Optional Provider Methods
**Goal**: Implement optional provider methods for better performance

- [ ] `latest_execution_id()` - Override for efficiency
  ```sql
  SELECT current_execution_id FROM schema_name.instances WHERE instance_id = ?;
  ```

- [ ] `list_instances()` - Return all instance IDs (basic implementation)
- [ ] `list_executions()` - Return execution IDs for instance (basic implementation)

### Phase 6.5: ManagementCapability Implementation
**Goal**: Implement rich management and observability features

**Note**: This enables powerful introspection and monitoring capabilities for production use.

- [ ] Implement `as_management_capability()` method on `Provider` trait
  - Return `Some(self)` to enable management features
  - This allows the Client to auto-discover management capabilities

- [ ] Implement `ManagementCapability` trait for `PostgresProvider`:

  - [ ] **Instance Discovery Methods**:
    - `list_instances()` - List all instance IDs sorted by creation time
      ```sql
      SELECT instance_id FROM schema_name.instances 
      ORDER BY created_at DESC
      ```
    - `list_instances_by_status(status)` - Filter instances by execution status
      ```sql
      SELECT DISTINCT i.instance_id 
      FROM schema_name.instances i
      JOIN schema_name.executions e ON i.instance_id = e.instance_id 
        AND i.current_execution_id = e.execution_id
      WHERE e.status = ?
      ORDER BY i.created_at DESC
      ```

  - [ ] **Execution Inspection Methods**:
    - `list_executions(instance)` - List all execution IDs for an instance
      ```sql
      SELECT execution_id FROM schema_name.executions 
      WHERE instance_id = ? 
      ORDER BY execution_id
      ```
    - `read_execution(instance, execution_id)` - Read history for specific execution
      ```sql
      SELECT event_data FROM schema_name.history 
      WHERE instance_id = ? AND execution_id = ? 
      ORDER BY event_id
      ```
    - `latest_execution_id(instance)` - Get current execution ID
      ```sql
      SELECT current_execution_id FROM schema_name.instances 
      WHERE instance_id = ?
      ```

  - [ ] **Instance Metadata Methods**:
    - `get_instance_info(instance)` - Get comprehensive instance information
      ```sql
      SELECT i.instance_id, i.orchestration_name, i.orchestration_version, 
             i.current_execution_id, i.created_at, i.updated_at,
             e.status, e.output, e.started_at, e.completed_at
      FROM schema_name.instances i
      LEFT JOIN schema_name.executions e ON i.instance_id = e.instance_id 
        AND i.current_execution_id = e.execution_id
      WHERE i.instance_id = ?
      ```
      Returns `InstanceInfo` struct with all instance details
    
    - `get_execution_info(instance, execution_id)` - Get detailed execution information
      ```sql
      SELECT e.instance_id, e.execution_id, e.status, e.output, 
             e.started_at, e.completed_at,
             COUNT(h.event_id) as event_count
      FROM schema_name.executions e
      LEFT JOIN schema_name.history h ON e.instance_id = h.instance_id 
        AND e.execution_id = h.execution_id
      WHERE e.instance_id = ? AND e.execution_id = ?
      GROUP BY e.instance_id, e.execution_id, e.status, e.output, 
               e.started_at, e.completed_at
      ```
      Returns `ExecutionInfo` struct with execution details and event count

  - [ ] **System Metrics Methods**:
    - `get_system_metrics()` - Get system-wide statistics
      ```sql
      SELECT 
        COUNT(DISTINCT i.instance_id) as total_instances,
        COUNT(DISTINCT e.instance_id || '-' || e.execution_id) as total_executions,
        COUNT(DISTINCT CASE WHEN e.status = 'Running' THEN i.instance_id END) as running_instances,
        COUNT(DISTINCT CASE WHEN e.status = 'Completed' THEN i.instance_id END) as completed_instances,
        COUNT(DISTINCT CASE WHEN e.status = 'Failed' THEN i.instance_id END) as failed_instances,
        COUNT(h.event_id) as total_events
      FROM schema_name.instances i
      LEFT JOIN schema_name.executions e ON i.instance_id = e.instance_id 
        AND i.current_execution_id = e.execution_id
      LEFT JOIN schema_name.history h ON i.instance_id = h.instance_id
      ```
      Returns `SystemMetrics` struct with counts
    
    - `get_queue_depths()` - Get current queue depths
      ```sql
      SELECT 
        (SELECT COUNT(*) FROM schema_name.orchestrator_queue 
         WHERE lock_token IS NULL OR locked_until <= NOW()) as orchestrator_queue,
        (SELECT COUNT(*) FROM schema_name.worker_queue 
         WHERE lock_token IS NULL OR locked_until <= NOW()) as worker_queue
      ```
      Returns `QueueDepths` struct (timer_queue = 0, timers are in orchestrator queue)

- [ ] Performance optimizations:
  - Use efficient JOINs for status filtering
  - Add indexes on frequently queried columns (status, created_at)
  - Consider caching metrics for high-traffic systems (optional, not required)
  - Use prepared statements (sqlx handles this automatically)

**Note**: Return types are defined in `duroxide::providers`:
- `InstanceInfo` - Contains instance_id, orchestration_name, orchestration_version, current_execution_id, status, output, created_at
- `ExecutionInfo` - Contains instance_id, execution_id, status, output, started_at, completed_at
- `SystemMetrics` - Contains total_instances, total_executions, running_instances, completed_instances, failed_instances, total_events
- `QueueDepths` - Contains orchestrator_queue, worker_queue, timer_queue (timer_queue = 0 for PostgreSQL)

### Phase 7: Error Handling & Validation
**Goal**: Add robust error handling and validation

- [ ] Validate runtime-provided IDs
  - Check `event.event_id() > 0` before storing
  - Verify `execution_id` is provided by runtime
  - Never modify or generate IDs

- [ ] Transaction error handling
  - Proper rollback on errors
  - Clear error messages
  - Handle constraint violations gracefully

- [ ] Lock expiration handling
  - Check `locked_until <= NOW()` when acquiring locks
  - Handle expired locks gracefully

### Phase 7.5: Observability & Instrumentation
**Goal**: Instrument provider for optimal observability with metrics and structured logging

**Note**: Check if `tracing` is already available via `duroxide` dependency. If not, add `tracing = "0.1"` to `Cargo.toml`. The `tracing` crate provides the instrumentation macros and logging infrastructure.

#### 7.5.1 Duration Metrics (Histograms)
**Goal**: Track operation latency for all critical operations

- [ ] `provider.fetch_orchestration_item_duration_ms` - Histogram
  - Instrument `fetch_orchestration_item()` method
  - Measure time from start to return
  - Log at DEBUG level with instance_id context

- [ ] `provider.ack_orchestration_item_duration_ms` - Histogram
  - Instrument `ack_orchestration_item()` method
  - Measure transaction commit time
  - Log at DEBUG level with instance_id context

- [ ] `provider.ack_worker_duration_ms` - Histogram
  - Instrument `ack_worker()` method
  - Measure atomic delete + enqueue time
  - Log at DEBUG level

- [ ] `provider.enqueue_orchestrator_duration_ms` - Histogram
  - Instrument `enqueue_orchestrator_work()` method
  - Measure enqueue time
  - Log at DEBUG level

- [ ] `provider.dequeue_worker_duration_ms` - Histogram
  - Instrument `dequeue_worker_peek_lock()` method
  - Measure lock acquisition time
  - Log at DEBUG level

#### 7.5.2 Error Metrics (Counters)
**Goal**: Track infrastructure errors by operation and type

- [ ] `provider.infrastructure_errors` - Counter
  - Labels: `operation` (fetch, ack_orch, ack_worker, enqueue), `error_type` (transaction_failed, lock_timeout, serialization_error, unknown)
  - Record on any database/transaction errors
  - Classify error types appropriately

- [ ] `provider.ack_orchestration_retries` - Counter
  - Track retry attempts for ack operations
  - Increment on each retry before success or final failure

#### 7.5.3 Structured Logging with Tracing
**Goal**: Add structured logging with context for all operations

- [ ] Add tracing instrumentation to all provider methods:
  - Use `#[tracing::instrument]` attribute with appropriate fields
  - Include `instance_id` in fields when available
  - Use DEBUG level for operations, ERROR for failures

- [ ] Operation spans:
  - `fetch_orchestration_item()` - Include instance_id in fields
  - `ack_orchestration_item()` - Include instance_id, execution_id
  - `ack_worker()` - Include token context
  - `enqueue_orchestrator_work()` - Include instance_id
  - `dequeue_worker_peek_lock()` - Basic span

- [ ] Error logging pattern:
  ```rust
  tracing::error!(
      operation = "ack_orchestration",
      error_type = "transaction_failed",
      error = %e,
      instance_id = %instance_id,
      "Failed to commit transaction"
  );
  ```

- [ ] Success logging pattern:
  ```rust
  tracing::debug!(
      instance_id = %instance_id,
      duration_ms = duration_ms,
      "Fetched orchestration item"
  );
  ```

#### 7.5.4 Queue Depth Metrics (via ManagementCapability)
**Goal**: Implement queue depth queries for observability

- [ ] `get_queue_depths()` method (already in Phase 6.5)
  - Count unlocked items: `WHERE lock_token IS NULL OR locked_until <= NOW()`
  - Return accurate counts for orchestrator_queue and worker_queue
  - timer_queue = 0 (timers in orchestrator queue with delayed visibility)

#### 7.5.5 Performance Guidelines
**Goal**: Ensure observability doesn't impact performance

- [ ] Use async operations - Don't block on metric recording
- [ ] Batch where possible - Aggregate before recording
- [ ] Sample expensive metrics - Not every operation needs metrics
- [ ] Use histograms wisely - Pre-allocated buckets, no dynamic allocation
- [ ] Log at appropriate levels:
  - DEBUG for normal operations
  - ERROR for failures
  - INFO sparingly (startup, shutdown, major events)

#### 7.5.6 Common Pitfalls to Avoid

- [ ] ❌ Don't block on metrics - Use non-blocking metric recording
- [ ] ❌ Don't log sensitive data - Never log connection strings, passwords, or PII
- [ ] ❌ Don't over-log - Use DEBUG level sparingly, avoid logging in hot paths
- [ ] ✅ Do sanitize data - Log instance IDs, execution IDs, but not user data
- [ ] ✅ Do record metrics asynchronously - Use metric counters, not sync exporters

### Phase 8: Testing
**Goal**: Comprehensive test coverage using provider-test framework

#### 8.1 Provider Validation Tests
**Goal**: Validate correctness properties (atomicity, locking, error handling, etc.)

**Note**: The `provider-test` feature is already enabled in `Cargo.toml`. This provides access to:
- `duroxide::provider_validations` module (validation test functions)
- `duroxide_stress_tests` module (stress test infrastructure)

**Environment Setup**: Tests can use the PostgreSQL connection string from `.env` file:
- Use `dotenvy::dotenv()` to load environment variables
- Read `DATABASE_URL` via `std::env::var("DATABASE_URL")`
- The `.env` file contains the connection string: `postgres://username:password@host:port/database`

- [ ] Implement `ProviderFactory` trait
  - Create factory struct that generates fresh provider instances
  - For PostgreSQL: use unique database per test or cleanup between tests
  - Handle schema creation for each test instance
  - Load `DATABASE_URL` from environment using `dotenvy::dotenv().ok()`
  
- [ ] Create test module (`tests/postgres_provider_test.rs`)
  - Import validation test functions from `duroxide::provider_validations`
  - Create separate test functions for each validation category
  
- [ ] Implement individual test suites:
  - `test_postgres_provider_atomicity()` - Uses `run_atomicity_tests()`
    - Validates all-or-nothing commit semantics
    - Validates rollback on failure
    - Validates single transaction guarantees
  - `test_postgres_provider_error_handling()` - Uses `run_error_handling_tests()`
    - Validates invalid lock token rejection
    - Validates duplicate event ID detection
    - Validates error propagation
  - `test_postgres_provider_instance_locking()` - Uses `run_instance_locking_tests()`
    - Validates exclusive access to instances
    - Validates lock timeout behavior
    - Validates concurrent access prevention
  - `test_postgres_provider_lock_expiration()` - Uses `run_lock_expiration_tests()`
    - Validates automatic lock release
    - Validates delayed visibility for retries
    - Validates reacquisition after expiration
  - `test_postgres_provider_multi_execution()` - Uses `run_multi_execution_tests()`
    - Validates execution isolation
    - Validates ContinueAsNew behavior
    - Validates execution ID tracking
  - `test_postgres_provider_queue_semantics()` - Uses `run_queue_semantics_tests()`
    - Validates FIFO ordering
    - Validates atomic queue operations
    - Validates worker queue isolation
  - `test_postgres_provider_management()` - Uses `run_management_tests()`
    - Validates instance listing and filtering
    - Validates execution queries
    - Validates system metrics
    - Validates queue depth reporting
    - **Note**: ManagementCapability is required for this provider

- [ ] Test isolation strategy:
  - Use unique database per test run (e.g., `duroxide_test_<timestamp>`)
  - Or use transaction rollback for cleanup
  - Ensure schema is created for each test instance
  - Handle custom schema tests separately
  - Load `DATABASE_URL` from `.env` file using `dotenvy::dotenv().ok()` at test start
  - Example pattern:
    ```rust
    #[tokio::test]
    async fn test_provider_atomicity() {
        dotenvy::dotenv().ok(); // Load .env file
        let database_url = std::env::var("DATABASE_URL")
            .expect("DATABASE_URL must be set");
        // Use database_url to create provider
    }
    ```

#### 8.2 Stress Tests (Performance & Throughput)
**Goal**: Measure performance, throughput, and scalability

- [ ] Create stress test binary (`examples/stress_test.rs` or `tests/stress_test.rs`)
  - Import `run_stress_test` from `duroxide_stress_tests`
  - Configure `StressTestConfig` for different scenarios
  
- [ ] Implement test configurations:
  - **Quick Validation** (30 seconds):
    ```rust
    StressTestConfig {
        max_concurrent: 10,
        duration_secs: 30,
        tasks_per_instance: 3,
        activity_delay_ms: 50,
        orch_concurrency: 1,
        worker_concurrency: 1,
    }
    ```
  - **Performance Baseline** (10 seconds):
    ```rust
    StressTestConfig {
        max_concurrent: 20,
        duration_secs: 10,
        tasks_per_instance: 5,
        activity_delay_ms: 10,
        orch_concurrency: 1,
        worker_concurrency: 1,
    }
    ```
  - **Concurrency Stress Test** (10 seconds):
    ```rust
    StressTestConfig {
        max_concurrent: 20,
        duration_secs: 10,
        tasks_per_instance: 5,
        activity_delay_ms: 10,
        orch_concurrency: 2,
        worker_concurrency: 2,
    }
    ```

- [ ] Add PostgreSQL-specific stress tests:
  - Connection pool stress tests (vary pool size)
  - Transaction isolation tests (concurrent transactions)
  - Schema support tests (custom schema creation, schema-qualified queries)
  - Index performance verification (with/without indexes)

#### 8.3 Performance Targets

- [ ] Minimum Requirements:
  - ✅ Success Rate: 100% under all configurations
  - ✅ Baseline Throughput: ≥ 10 orch/sec (1/1 config)
  - ✅ Latency: Average < 200ms per orchestration
  - ✅ Scalability: 2/2 config increases throughput by ≥ 30%

- [ ] High-Performance Targets:
  - Throughput: ≥ 50 orch/sec (2/2 config)
  - Latency: Average < 100ms per orchestration
  - Scalability: Linear throughput increase with concurrency

#### 8.4 Observability Testing

- [ ] Unit tests for metrics:
  - Verify duration metrics are recorded for all operations
  - Verify error metrics are recorded with correct labels
  - Verify retry metrics increment correctly
  - Use tracing-test crate for log verification

- [ ] Integration tests for observability:
  - Run under load and verify no performance degradation
  - Verify all metrics populated correctly
  - Verify structured logs contain expected fields
  - Test error scenarios and verify error metrics

#### 8.5 CI/CD Integration

- [ ] Add test configuration to CI pipeline:
  - Run validation tests on every PR
  - Run stress tests on PR and scheduled runs
  - Use PostgreSQL service in CI (GitHub Actions, etc.)
  - Configure test database connection string via environment variables
    - For CI: Set `DATABASE_URL` environment variable directly
    - For local: Use `.env` file with `dotenvy::dotenv().ok()`
  - Verify observability metrics in CI runs

## PostgreSQL-Specific Considerations

### Schema Support
1. **Optional Schema Name**: Provider accepts optional `schema_name` parameter
   - Defaults to `"public"` schema if not specified
   - Creates schema if it doesn't exist (`CREATE SCHEMA IF NOT EXISTS`)
   - All table operations use schema-qualified names: `schema_name.table_name`
   - Set `search_path` in connection or use fully qualified names in queries

2. **Schema Qualification in Queries**:
   - All SQL queries must use schema-qualified table names
   - Example: `SELECT * FROM my_schema.instances` instead of `SELECT * FROM instances`
   - Helper method: `table_name("instances")` → `"my_schema.instances"`
   - Migration file should handle schema creation before table creation

### Differences from SQLite
1. **Locking**: Use `SELECT FOR UPDATE SKIP LOCKED` instead of SQLite's row locks
2. **Timestamps**: Use `TIMESTAMPTZ` instead of `INTEGER` for better timezone handling
3. **Auto-increment**: Use `SERIAL` or `BIGSERIAL` instead of `AUTOINCREMENT`
4. **Concurrency**: PostgreSQL handles concurrent access better (no WAL mode needed)
5. **Transactions**: Use `BEGIN`/`COMMIT`/`ROLLBACK` explicitly

### Performance Optimizations
1. **Connection Pooling**: Use `PgPoolOptions` with appropriate `max_connections` (10-20)
2. **Indexes**: All indexes from SQLite schema are critical
3. **Query Optimization**: Use prepared statements (sqlx handles this)
4. **Batch Operations**: Use `INSERT ... VALUES (...), (...), (...)` for bulk inserts

### Schema Conversion Notes
- `TEXT` → `TEXT` (same)
- `INTEGER` → `BIGINT` (for execution_id, event_id)
- `TIMESTAMP` → `TIMESTAMPTZ` (with timezone)
- `AUTOINCREMENT` → `SERIAL` or `BIGSERIAL`
- `PRAGMA` statements → PostgreSQL-specific settings (not needed)
- `NOW()` → `NOW()` or `CURRENT_TIMESTAMP`
- Milliseconds for `locked_until` → Use `BIGINT` for Unix timestamp in milliseconds
- **Schema Qualification**: All table references use `schema_name.table_name` format
- **Schema Creation**: `CREATE SCHEMA IF NOT EXISTS schema_name` before table creation

## Implementation Order

1. **Schema** (Phase 1) - Foundation for everything
2. **Helpers** (Phase 1) - Needed by all methods
3. **History methods** (Phase 3) - Simplest, builds confidence
4. **Worker queue** (Phase 4) - Simpler than orchestrator queue
5. **Orchestrator queue** (Phase 5) - Needed by fetch/ack
6. **Core orchestration** (Phase 2) - Most complex, depends on other phases
7. **Optional methods** (Phase 6) - Nice to have
8. **ManagementCapability** (Phase 6.5) - Rich observability features
9. **Error handling** (Phase 7) - Refinement
10. **Observability** (Phase 7.5) - Metrics and structured logging
11. **Tests** (Phase 8) - Validation

## Success Criteria

### Validation Tests
- [ ] All validation test suites pass:
  - ✅ Atomicity tests - 100% pass
  - ✅ Error handling tests - 100% pass
  - ✅ Instance locking tests - 100% pass
  - ✅ Lock expiration tests - 100% pass
  - ✅ Multi-execution tests - 100% pass
  - ✅ Queue semantics tests - 100% pass
  - ✅ Management tests - 100% pass (ManagementCapability required)

### Correctness Requirements
- [ ] `fetch_orchestration_item()` returns None when queue empty
- [ ] `ack_orchestration_item()` is fully atomic (single transaction)
- [ ] Lock expiration works (messages redelivered after timeout)
- [ ] Multi-execution support (ContinueAsNew creates execution 2, 3, ...)
- [ ] Execution metadata stored correctly (status, output)
- [ ] History ordering preserved (events returned in event_id order)
- [ ] Concurrent access safe (run with `RUST_TEST_THREADS=10`)
- [ ] No event content inspection (use ExecutionMetadata only)
- [ ] Worker queue FIFO behavior
- [ ] No duplicate event IDs (PRIMARY KEY enforced)

### ManagementCapability Requirements
- [ ] `as_management_capability()` returns `Some(self)`
- [ ] All 9 ManagementCapability methods implemented:
  - ✅ `list_instances()` - Returns all instance IDs
  - ✅ `list_instances_by_status()` - Filters by status
  - ✅ `list_executions()` - Lists execution IDs for instance
  - ✅ `read_execution()` - Reads history for specific execution
  - ✅ `latest_execution_id()` - Returns current execution ID
  - ✅ `get_instance_info()` - Returns comprehensive instance info
  - ✅ `get_execution_info()` - Returns detailed execution info
  - ✅ `get_system_metrics()` - Returns system-wide statistics
  - ✅ `get_queue_depths()` - Returns queue depth information
- [ ] All queries use schema-qualified table names
- [ ] Efficient JOINs for status filtering
- [ ] Proper error handling for missing instances/executions

### Performance Requirements
- [ ] Success Rate: 100% under all stress test configurations
- [ ] Baseline Throughput: ≥ 10 orch/sec (1/1 config)
- [ ] Latency: Average < 200ms per orchestration
- [ ] Scalability: 2/2 config increases throughput by ≥ 30%

### Observability Requirements
- [ ] All duration metrics implemented and recorded:
  - ✅ `fetch_orchestration_item_duration_ms`
  - ✅ `ack_orchestration_item_duration_ms`
  - ✅ `ack_worker_duration_ms`
  - ✅ `enqueue_orchestrator_duration_ms`
  - ✅ `dequeue_worker_duration_ms`
- [ ] Error metrics implemented:
  - ✅ `infrastructure_errors` with correct labels
  - ✅ `ack_orchestration_retries` tracking
- [ ] Structured logging with tracing:
  - ✅ All operations instrumented with spans
  - ✅ Instance ID context in logs
  - ✅ Error logging with structured fields
  - ✅ No sensitive data in logs
- [ ] Performance impact:
  - ✅ No significant performance degradation from observability
  - ✅ Non-blocking metric recording
  - ✅ Appropriate log levels (DEBUG for operations, ERROR for failures)

## Reference Materials

### Documentation
- **Provider Implementation Guide**: https://github.com/affandar/duroxide/blob/main/docs/provider-implementation-guide.md
- **Provider Testing Guide**: https://github.com/affandar/duroxide/blob/main/docs/provider-testing-guide.md
- **Provider Observability Guide**: https://github.com/affandar/duroxide/blob/main/docs/provider-observability.md
- **Architecture**: https://github.com/affandar/duroxide/blob/main/docs/architecture.md

### Code References
- **SQLite Provider (Reference Implementation)**: `src/providers/sqlite.rs`
- **SQLite Schema**: `migrations/20240101000000_initial_schema.sql`
- **Provider Validation Tests**: `src/provider_validations/mod.rs` (test framework)
- **Stress Test Implementation**: `stress-tests/src/lib.rs`
- **Stress Test Binary**: `stress-tests/src/bin/parallel_orchestrations.rs`

### Testing Framework
- **ProviderFactory Trait**: `duroxide::provider_validations::ProviderFactory`
- **Validation Test Functions**: `duroxide::provider_validations::{run_atomicity_tests, run_error_handling_tests, ...}`
- **Stress Test Function**: `duroxide_stress_tests::run_stress_test`
- **Stress Test Config**: `duroxide_stress_tests::StressTestConfig`

## Detailed Method Specifications

### `fetch_orchestration_item()` - Detailed Steps

```sql
-- Step 1: Find available instance (atomic lock acquisition)
-- Use SELECT FOR UPDATE SKIP LOCKED to atomically claim an instance
-- Note: schema_name is stored in provider and used for all table references
SELECT q.instance_id 
FROM schema_name.orchestrator_queue q
LEFT JOIN schema_name.instance_locks il ON q.instance_id = il.instance_id
WHERE q.visible_at <= NOW()
  AND (il.instance_id IS NULL OR il.locked_until <= NOW())
ORDER BY q.id
LIMIT 1
FOR UPDATE SKIP LOCKED;

-- Step 2: Atomically acquire instance lock
INSERT INTO schema_name.instance_locks (instance_id, lock_token, locked_until, locked_at)
VALUES (?, ?, ?, ?)
ON CONFLICT (instance_id) DO UPDATE
SET lock_token = excluded.lock_token,
    locked_until = excluded.locked_until,
    locked_at = excluded.locked_at
WHERE schema_name.instance_locks.locked_until <= excluded.locked_at;

-- Step 3: Lock all visible messages for instance
UPDATE schema_name.orchestrator_queue
SET lock_token = ?, locked_until = ?
WHERE instance_id = ? 
  AND visible_at <= NOW()
  AND (lock_token IS NULL OR locked_until <= NOW());

-- Step 4: Load instance metadata
SELECT orchestration_name, orchestration_version, current_execution_id
FROM schema_name.instances
WHERE instance_id = ?;

-- Step 5: Load history for current execution_id
SELECT event_data 
FROM schema_name.history 
WHERE instance_id = ? AND execution_id = ?
ORDER BY event_id;

-- Step 6: Fetch locked messages
SELECT work_item 
FROM schema_name.orchestrator_queue
WHERE lock_token = ?
ORDER BY id;
```

### `ack_orchestration_item()` - Transaction Steps

```sql
BEGIN;

-- Step 1: Validate lock token
SELECT instance_id FROM schema_name.instance_locks
WHERE lock_token = ? AND locked_until > NOW();

-- Step 2: Remove instance lock
DELETE FROM schema_name.instance_locks WHERE lock_token = ?;

-- Step 3: Idempotently create execution
INSERT INTO schema_name.executions (instance_id, execution_id, status, started_at)
VALUES (?, ?, 'Running', NOW())
ON CONFLICT (instance_id, execution_id) DO NOTHING;

-- Step 4: Update instance current_execution_id
UPDATE schema_name.instances
SET current_execution_id = GREATEST(current_execution_id, ?)
WHERE instance_id = ?;

-- Step 5: Append history_delta
-- (Loop through events, validate event_id > 0)
INSERT INTO schema_name.history (instance_id, execution_id, event_id, event_type, event_data)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT (instance_id, execution_id, event_id) DO NOTHING;

-- Step 6: Update execution metadata
UPDATE schema_name.executions
SET status = ?, output = ?, completed_at = CASE WHEN ? IN ('Completed', 'Failed') THEN NOW() ELSE NULL END
WHERE instance_id = ? AND execution_id = ?;

-- Step 7: Enqueue worker items
INSERT INTO schema_name.worker_queue (work_item, created_at)
VALUES (?, NOW());

-- Step 8: Enqueue orchestrator items
-- Handle StartOrchestration specially
-- Set visible_at based on delay_ms or TimerFired.fire_at_ms
INSERT INTO schema_name.orchestrator_queue (instance_id, work_item, visible_at, created_at)
VALUES (?, ?, ?, NOW());

-- Step 9: Delete locked messages
DELETE FROM schema_name.orchestrator_queue WHERE lock_token = ?;

COMMIT;
```

## Common Pitfalls to Avoid

1. ❌ **DON'T generate IDs** - Runtime provides all IDs
2. ❌ **DON'T inspect events** - Use ExecutionMetadata
3. ❌ **DON'T break atomicity** - Single transaction for ack
4. ❌ **DON'T forget instance locks** - Critical for concurrency
5. ❌ **DON'T skip lock validation** - Check lock_token before operations
6. ❌ **DON'T forget idempotency** - Use ON CONFLICT DO NOTHING
7. ❌ **DON'T forget schema qualification** - All table references must use `schema_name.table_name`
8. ❌ **DON'T forget schema creation** - Create schema before creating tables if custom schema specified

