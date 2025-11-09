# Stored Procedure Migration Status

**Last Updated:** November 9, 2024  
**Status:** 12/20 procedures implemented (60%)

---

## Current Implementation Status

### ✅ Implemented (12 procedures)

**Management Operations:**
1. ✅ `cleanup_schema()` - Drops all tables
2. ✅ `list_instances()` - List all instances
3. ✅ `list_executions(p_instance_id)` - List executions for instance
4. ✅ `latest_execution_id(p_instance_id)` - Get latest execution ID
5. ✅ `list_instances_by_status(p_status)` - Filter instances by status
6. ✅ `get_instance_info(p_instance_id)` - Get instance details with JOIN
7. ✅ `get_execution_info(p_instance_id, p_execution_id)` - Get execution details with COUNT
8. ✅ `get_system_metrics()` - System-wide aggregate metrics
9. ✅ `get_queue_depths(p_now_ms)` - Queue depth counts

**Queue Operations:**
10. ✅ `enqueue_worker_work(p_work_item)` - Enqueue worker work
11. ✅ `ack_worker(p_lock_token, p_instance_id, p_completion_json)` - Ack worker atomically
12. ✅ `enqueue_orchestrator_work(...)` - Enqueue orchestrator work

**Performance Impact:** Minor (management APIs are low-frequency, 1-2 queries each)

### ⚠️ Not Implemented - Critical Path (8 procedures)

**HIGH IMPACT - Core Provider Operations:**

1. ❌ **`fetch_orchestration_item()`** ⭐ CRITICAL
   - **Current:** 6-7 queries, ~2,200ms with Azure
   - **Target:** 1 query, ~200ms with Azure
   - **Savings:** ~2,000ms per fetch (90% reduction)
   - **Complexity:** Very High (transaction, locking, conditional logic)

2. ❌ **`ack_orchestration_item()`** ⭐ CRITICAL
   - **Current:** 8-9 queries, ~1,700ms with Azure
   - **Target:** 1 query, ~200ms with Azure
   - **Savings:** ~1,500ms per ack (88% reduction)
   - **Complexity:** Very High (large transaction, many operations)

3. ❌ **`abandon_orchestration_item()`**
   - **Current:** 3-4 queries, ~600ms with Azure
   - **Target:** 1 query, ~180ms with Azure
   - **Savings:** ~420ms per abandon (70% reduction)
   - **Complexity:** Medium

**MEDIUM IMPACT - Worker Queue Operations:**

4. ❌ **`fetch_work_item()` (dequeue_worker_peek_lock)**
   - **Current:** 2-3 queries in transaction, ~300-500ms
   - **Target:** 1 query, ~180ms
   - **Savings:** ~200ms per dequeue (40% reduction)
   - **Complexity:** High (SELECT FOR UPDATE + UPDATE)

**LOW IMPACT - History Operations:**

5. ❌ `read()` - Read current history
   - **Current:** 2 queries, ~350ms
   - **Target:** 1 query, ~180ms
   - **Savings:** ~170ms per read
   - **Complexity:** Low

6. ❌ `read_with_execution()` - Read specific execution
   - **Current:** 1 query, ~180ms
   - **Target:** Already optimal (single query)
   - **Savings:** Minimal
   - **Complexity:** Low

7. ❌ `append_with_execution()` - Append history batch
   - **Current:** Loop with N inserts in transaction
   - **Target:** Single batch insert via UNNEST
   - **Savings:** Moderate for large batches
   - **Complexity:** Medium

**SPECIAL CASE:**

8. ❌ `initialize_schema()` - Already uses migration system
   - Not worth converting to stored procedure
   - DDL operations handled by migration runner

---

## Performance Impact Analysis

### Current State (Remote Azure PostgreSQL)

**Per-turn metrics:**
- **Fetch:** ~2,200ms (6-7 queries)
- **Ack:** ~1,700ms (8-9 queries)
- **Total turn time:** ~3,900ms (3.9 seconds)

### After Full Migration

**Expected per-turn metrics:**
- **Fetch:** ~200ms (1 stored procedure call)
- **Ack:** ~200ms (1 stored procedure call)
- **Total turn time:** ~400ms (0.4 seconds)

**🎯 Overall improvement: 10× faster (90% reduction)**

### ROI by Procedure

| Procedure | Priority | Current Time | Target Time | Savings | Impact |
|-----------|----------|--------------|-------------|---------|--------|
| `fetch_orchestration_item` | ⭐⭐⭐ | 2,200ms | 200ms | 2,000ms | **Critical** |
| `ack_orchestration_item` | ⭐⭐⭐ | 1,700ms | 200ms | 1,500ms | **Critical** |
| `abandon_orchestration_item` | ⭐⭐ | 600ms | 180ms | 420ms | High |
| `fetch_work_item` | ⭐⭐ | 400ms | 180ms | 220ms | Medium |
| `read` | ⭐ | 350ms | 180ms | 170ms | Low |

---

## Recommended Implementation Order

### Phase 1: Critical Path - Core Orchestration (HIGHEST ROI)

**Implement these two first - they account for 90% of the performance gain:**

1. **`sp_fetch_orchestration_item()`** 
   - Estimated effort: 2-3 days
   - Complexity: Very High
   - ROI: 2,000ms savings
   
2. **`sp_ack_orchestration_item()`**
   - Estimated effort: 2-3 days
   - Complexity: Very High
   - ROI: 1,500ms savings

**After Phase 1:** Turn time reduces from ~3.9s → ~0.4s (10× improvement)

### Phase 2: Worker Queue Operations

3. **`sp_fetch_work_item()`** (dequeue_worker_peek_lock)
   - Estimated effort: 1 day
   - Complexity: High
   - ROI: 220ms savings

### Phase 3: Supporting Operations

4. **`sp_abandon_orchestration_item()`**
   - Estimated effort: 1 day
   - Complexity: Medium
   - ROI: 420ms savings

5. **`sp_read()` / `sp_read_with_execution()`**
   - Estimated effort: 0.5 days
   - Complexity: Low
   - ROI: 170ms savings

6. **`sp_append_with_execution()`**
   - Estimated effort: 1 day
   - Complexity: Medium
   - ROI: Variable (depends on batch size)

---

## Implementation Plan Updated

### Week 1: Core Orchestration (Critical Path)

**Goal:** Implement the two most impactful procedures

**Day 1-2: Design `sp_fetch_orchestration_item`**
- [ ] Design procedure signature with JSONB returns
- [ ] Implement multi-step transaction logic
- [ ] Handle instance lock acquisition
- [ ] Implement message batching
- [ ] Handle metadata fallback logic
- [ ] Test with various scenarios

**Day 3-4: Design `sp_ack_orchestration_item`**
- [ ] Design procedure with JSONB parameters
- [ ] Implement lock validation
- [ ] Implement instance/execution creation
- [ ] Implement history append (batch)
- [ ] Implement metadata updates
- [ ] Implement worker/orchestrator item enqueue
- [ ] Test atomicity and rollback

**Day 5: Integration & Testing**
- [ ] Update Rust code to call new procedures
- [ ] Run full test suite (79 tests)
- [ ] Benchmark performance improvement
- [ ] Document procedures

**Expected outcome:** 10× faster turn times on remote database

### Week 2: Worker Queue & Supporting Operations

**Day 6-7: Worker Queue**
- [ ] Implement `sp_fetch_work_item()`
- [ ] Test concurrency

**Day 8: Orchestration Support**
- [ ] Implement `sp_abandon_orchestration_item()`
- [ ] Test with retries and delays

**Day 9-10: History Operations**
- [ ] Implement `sp_read()` / `sp_read_with_execution()`
- [ ] Implement `sp_append_with_execution()` with UNNEST for batch insert
- [ ] Test and verify

---

## Key Design Decisions

### 1. Return Type for Complex Data

**Use JSONB for complex returns:**

```sql
CREATE FUNCTION sp_fetch_orchestration_item(...)
RETURNS TABLE(
    instance_id TEXT,
    orchestration_name TEXT,
    orchestration_version TEXT,
    execution_id BIGINT,
    history JSONB,      -- Array of events
    messages JSONB,     -- Array of work items
    lock_token TEXT
)
```

**Rationale:**
- Avoids creating custom composite types
- Flexible for schema changes
- Easy to parse in Rust with serde_json

### 2. Transaction Handling

**All procedures handle their own transactions:**
- BEGIN at start of procedure
- COMMIT at end if successful
- ROLLBACK and RAISE EXCEPTION on errors

**Rationale:**
- Atomic operations guaranteed
- Simplified Rust code (no transaction management)
- Better error handling

### 3. Error Handling

**Use RAISE EXCEPTION with meaningful messages:**
```sql
IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid lock token';
END IF;
```

**Map to ProviderError in Rust:**
```rust
.map_err(|e| Self::sqlx_to_provider_error("operation_name", e))
```

---

## Technical Challenges

### Challenge 1: Returning Complex Data

**Problem:** `fetch_orchestration_item` returns:
- Instance metadata (strings, numbers)
- History (array of events - complex JSON)
- Messages (array of work items - complex JSON)
- Lock token (string)

**Solution:** Use JSONB arrays

```sql
RETURNS TABLE(
    ...
    history JSONB,      -- [{"event_id": 1, "event_type": "OrchestrationStarted", ...}, ...]
    messages JSONB,     -- [{"instance": "...", "orchestration": "...", ...}, ...]
    ...
)
```

**Rust parsing:**
```rust
let history_json: serde_json::Value = row.get("history");
let history: Vec<Event> = serde_json::from_value(history_json)?;
```

### Challenge 2: Dynamic Instance Metadata Handling

**Problem:** Instance might not exist in `instances` table yet (validation tests, race conditions)

**Solution:** Implement fallback logic in procedure:
1. Try to load from `instances` table
2. If not found, check `history` table for `OrchestrationStarted` event
3. If not found, check `messages` for `StartOrchestration` work item
4. Use placeholder if nothing found

**This matches current Rust implementation.**

### Challenge 3: Lock Acquisition with SKIP LOCKED

**Problem:** `SELECT FOR UPDATE SKIP LOCKED` semantics must be preserved

**Solution:** Use explicit locking in procedure:
```sql
-- Find and lock row atomically
SELECT q.instance_id INTO v_instance_id
FROM orchestrator_queue q
WHERE ...
FOR UPDATE SKIP LOCKED
LIMIT 1;
```

### Challenge 4: Batch Operations in `ack_orchestration_item`

**Problem:** Enqueue multiple worker/orchestrator items (dynamic count)

**Solution:** Use JSONB arrays and JSONB_ARRAY_ELEMENTS:
```sql
-- Enqueue worker items from JSONB array
INSERT INTO worker_queue (work_item, created_at)
SELECT value::TEXT, NOW()
FROM JSONB_ARRAY_ELEMENTS(p_worker_items);
```

---

## Example: fetch_orchestration_item Procedure Design

### Signature

```sql
CREATE OR REPLACE FUNCTION sp_fetch_orchestration_item(
    p_now_ms BIGINT,
    p_lock_timeout_ms BIGINT
)
RETURNS TABLE(
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
    v_orchestration_name TEXT;
    v_orchestration_version TEXT;
    v_current_execution_id BIGINT;
    v_history JSONB;
    v_messages JSONB;
BEGIN
    -- Step 1: Find available instance with SELECT FOR UPDATE SKIP LOCKED
    SELECT q.instance_id INTO v_instance_id
    FROM orchestrator_queue q
    WHERE q.visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
      AND NOT EXISTS (
        SELECT 1 FROM instance_locks il
        WHERE il.instance_id = q.instance_id AND il.locked_until > p_now_ms
      )
    ORDER BY q.visible_at, q.id
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    IF NOT FOUND THEN
        RETURN; -- No available instances
    END IF;

    -- Step 2: Acquire instance lock
    v_lock_token := 'lock_' || gen_random_uuid()::TEXT;
    v_locked_until := p_now_ms + p_lock_timeout_ms;

    INSERT INTO instance_locks (instance_id, lock_token, locked_until, locked_at)
    VALUES (v_instance_id, v_lock_token, v_locked_until, p_now_ms)
    ON CONFLICT(instance_id) DO UPDATE
    SET lock_token = EXCLUDED.lock_token,
        locked_until = EXCLUDED.locked_until,
        locked_at = EXCLUDED.locked_at
    WHERE instance_locks.locked_until <= p_now_ms;

    IF NOT FOUND THEN
        RETURN; -- Failed to acquire lock
    END IF;

    -- Step 3: Mark messages with lock token
    UPDATE orchestrator_queue
    SET lock_token = v_lock_token,
        locked_until = v_locked_until
    WHERE instance_id = v_instance_id
      AND visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
      AND (lock_token IS NULL OR locked_until <= p_now_ms);

    -- Step 4: Fetch all locked messages as JSONB array
    SELECT JSONB_AGG(work_item::JSONB ORDER BY id) INTO v_messages
    FROM orchestrator_queue
    WHERE lock_token = v_lock_token;

    -- Step 5: Load instance metadata
    SELECT orchestration_name, orchestration_version, current_execution_id
    INTO v_orchestration_name, v_orchestration_version, v_current_execution_id
    FROM instances
    WHERE instance_id = v_instance_id;

    -- Step 6: Load history or implement fallback
    IF FOUND THEN
        -- Instance exists, load its history
        SELECT COALESCE(JSONB_AGG(event_data::JSONB ORDER BY event_id), '[]'::JSONB) INTO v_history
        FROM history
        WHERE instance_id = v_instance_id AND execution_id = v_current_execution_id;
    ELSE
        -- Fallback: load history from history table (validation test scenario)
        SELECT COALESCE(JSONB_AGG(event_data::JSONB ORDER BY execution_id, event_id), '[]'::JSONB) INTO v_history
        FROM history
        WHERE instance_id = v_instance_id;

        -- Extract metadata from history or messages
        -- (Implementation would match current Rust fallback logic)
        v_orchestration_name := 'Unknown';
        v_orchestration_version := 'unknown';
        v_current_execution_id := 1;
    END IF;

    -- Return single row with all data
    RETURN QUERY SELECT
        v_instance_id,
        v_orchestration_name,
        COALESCE(v_orchestration_version, 'unknown'),
        v_current_execution_id,
        v_history,
        v_messages,
        v_lock_token;
END;
$$ LANGUAGE plpgsql;
```

**Complexity Notes:**
- Transaction management: implicit (procedure creates its own transaction)
- Lock acquisition: must handle concurrent access with SKIP LOCKED
- Fallback logic: must match current Rust implementation
- Return type: JSONB arrays for complex data

---

## Example: ack_orchestration_item Procedure Design

### Signature

```sql
CREATE OR REPLACE FUNCTION sp_ack_orchestration_item(
    p_lock_token TEXT,
    p_execution_id BIGINT,
    p_history_delta JSONB,        -- Array of events
    p_worker_items JSONB,          -- Array of work items
    p_orchestrator_items JSONB,    -- Array of work items
    p_metadata JSONB               -- ExecutionMetadata: {orchestration_name, orchestration_version, status, output}
)
RETURNS VOID AS $$
DECLARE
    v_instance_id TEXT;
    v_now_ms BIGINT;
    v_orchestration_name TEXT;
    v_orchestration_version TEXT;
    v_status TEXT;
    v_output TEXT;
    v_completed_at TIMESTAMPTZ;
BEGIN
    v_now_ms := EXTRACT(EPOCH FROM NOW()) * 1000;

    -- Step 1: Validate lock token
    SELECT instance_id INTO v_instance_id
    FROM instance_locks
    WHERE lock_token = p_lock_token AND locked_until > v_now_ms;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid lock token';
    END IF;

    -- Step 2: Extract metadata from JSONB
    v_orchestration_name := p_metadata->>'orchestration_name';
    v_orchestration_version := p_metadata->>'orchestration_version';
    v_status := p_metadata->>'status';
    v_output := p_metadata->>'output';

    -- Step 3: Create or update instance metadata
    IF v_orchestration_name IS NOT NULL AND v_orchestration_version IS NOT NULL THEN
        INSERT INTO instances (instance_id, orchestration_name, orchestration_version, current_execution_id)
        VALUES (v_instance_id, v_orchestration_name, v_orchestration_version, p_execution_id)
        ON CONFLICT (instance_id) DO NOTHING;

        UPDATE instances
        SET orchestration_name = v_orchestration_name,
            orchestration_version = v_orchestration_version
        WHERE instance_id = v_instance_id;
    END IF;

    -- Step 4: Create execution record (idempotent)
    INSERT INTO executions (instance_id, execution_id, status, started_at)
    VALUES (v_instance_id, p_execution_id, 'Running', NOW())
    ON CONFLICT (instance_id, execution_id) DO NOTHING;

    -- Step 5: Update instance current_execution_id
    UPDATE instances
    SET current_execution_id = GREATEST(current_execution_id, p_execution_id)
    WHERE instance_id = v_instance_id;

    -- Step 6: Append history_delta (batch insert)
    IF JSONB_ARRAY_LENGTH(p_history_delta) > 0 THEN
        INSERT INTO history (instance_id, execution_id, event_id, event_type, event_data)
        SELECT
            v_instance_id,
            p_execution_id,
            (elem->>'event_id')::BIGINT,
            elem->>'event_type',
            elem::TEXT
        FROM JSONB_ARRAY_ELEMENTS(p_history_delta) AS elem;
    END IF;

    -- Step 7: Update execution status if provided
    IF v_status IS NOT NULL THEN
        v_completed_at := CASE WHEN v_status IN ('Completed', 'Failed') THEN NOW() ELSE NULL END;
        
        UPDATE executions
        SET status = v_status, output = v_output, completed_at = v_completed_at
        WHERE instance_id = v_instance_id AND execution_id = p_execution_id;
    END IF;

    -- Step 8: Enqueue worker items (batch)
    IF JSONB_ARRAY_LENGTH(p_worker_items) > 0 THEN
        INSERT INTO worker_queue (work_item, created_at)
        SELECT elem::TEXT, NOW()
        FROM JSONB_ARRAY_ELEMENTS(p_worker_items) AS elem;
    END IF;

    -- Step 9: Enqueue orchestrator items (batch with delays)
    IF JSONB_ARRAY_LENGTH(p_orchestrator_items) > 0 THEN
        INSERT INTO orchestrator_queue (instance_id, work_item, visible_at, created_at)
        SELECT
            -- Extract instance from work item (complex)
            CASE
                WHEN elem->>'type' = 'TimerFired' THEN
                    TO_TIMESTAMP((elem->>'fire_at_ms')::BIGINT / 1000.0)
                ELSE
                    NOW()
            END,
            elem::TEXT,
            NOW()
        FROM JSONB_ARRAY_ELEMENTS(p_orchestrator_items) AS elem;
    END IF;

    -- Step 10: Delete locked messages
    DELETE FROM orchestrator_queue WHERE lock_token = p_lock_token;

    -- Step 11: Remove instance lock
    DELETE FROM instance_locks WHERE instance_id = v_instance_id AND lock_token = p_lock_token;
END;
$$ LANGUAGE plpgsql;
```

---

## Challenges & Solutions

### Challenge 1: Extracting Instance ID from Work Items

**Problem:** Work items have different structures (StartOrchestration vs TimerFired vs ActivityCompleted)

**Solution:** 
- Add `"type"` field when serializing work items in Rust
- Use CASE statement in SQL to extract instance based on type
- OR: Extract instance in Rust before calling procedure (simpler)

**Recommended:** Extract instance ID in Rust, pass as parameter to procedure

### Challenge 2: Handling fire_at_ms for TimerFired

**Problem:** `TimerFired` work items use `fire_at_ms` for delayed visibility

**Solution:**
```sql
INSERT INTO orchestrator_queue (instance_id, work_item, visible_at, created_at)
SELECT
    p_instance_id,
    elem::TEXT,
    CASE
        WHEN elem->>'fire_at_ms' IS NOT NULL AND (elem->>'fire_at_ms')::BIGINT > 0 THEN
            TO_TIMESTAMP((elem->>'fire_at_ms')::BIGINT / 1000.0)
        ELSE
            NOW()
    END AS visible_at,
    NOW()
FROM JSONB_ARRAY_ELEMENTS(p_orchestrator_items) AS elem;
```

### Challenge 3: Preserving Retry Logic

**Problem:** Rust code has retry logic with backoff (3 attempts)

**Solution:** Keep retry logic in Rust, procedure returns NULL/empty result on failure

```rust
for attempt in 0..=3 {
    let result = self.sp_fetch_orchestration_item(...).await?;
    if result.is_some() {
        return Ok(result);
    }
    if attempt < 3 {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}
Ok(None)
```

---

## Testing Strategy

### For Each Procedure

1. **Unit Test:** Test procedure directly via SQL
   ```sql
   SELECT * FROM sp_fetch_orchestration_item(1234567890, 30000);
   ```

2. **Integration Test:** Test via Rust Provider trait
   ```rust
   let item = provider.fetch_orchestration_item().await?;
   ```

3. **Concurrency Test:** Multiple workers accessing simultaneously
4. **Edge Cases:** Empty results, NULL values, errors
5. **Performance Test:** Measure before/after
6. **Regression Test:** Run full test suite

---

## Migration Script Structure

### Updated 0002_create_stored_procedures.sql

```sql
-- Migration 0002: Create Stored Procedures
-- This migration creates stored procedures for all provider operations

DO $$
DECLARE
    v_schema_name TEXT := current_schema();
BEGIN
    -- PHASE 1: Management Operations (COMPLETED)
    -- cleanup_schema, list_instances, list_executions, etc.
    -- (12 procedures already created)

    -- PHASE 2: Core Orchestration Operations (PRIORITY)
    
    -- Create sp_fetch_orchestration_item
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.sp_fetch_orchestration_item(...)
        RETURNS TABLE(...) AS $fetch$
        BEGIN
            -- Implementation
        END;
        $fetch$ LANGUAGE plpgsql;
    ', v_schema_name);

    -- Create sp_ack_orchestration_item
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.sp_ack_orchestration_item(...)
        RETURNS VOID AS $ack$
        BEGIN
            -- Implementation
        END;
        $ack$ LANGUAGE plpgsql;
    ', v_schema_name);

    -- PHASE 3: Worker Queue Operations
    -- sp_fetch_work_item, etc.

    -- PHASE 4: Supporting Operations
    -- sp_abandon, sp_read, sp_append, etc.
END $$;
```

---

## Success Metrics

### Performance Goals

- **Turn time:** <500ms on remote database (currently ~3,900ms)
- **Query count:** 2 per turn (currently 15-16)
- **Throughput:** 100+ turns/min/worker (currently ~15)

### Quality Goals

- **Test coverage:** All 79 tests pass
- **No regression:** Behavior identical to inline SQL
- **Error handling:** Proper ProviderError classification

---

## Next Steps

1. **Approve approach** - Review procedure designs
2. **Implement Phase 1** - `sp_fetch_orchestration_item`
3. **Test & benchmark** - Measure performance improvement
4. **Implement Phase 1** - `sp_ack_orchestration_item`
5. **Test & benchmark** - Measure combined improvement
6. **Continue phases** - Worker queue, supporting operations
7. **Final integration** - Remove inline SQL, documentation

---

## Appendix: Current vs Target State

### Current State

**Rust code has 15-16 queries per turn:**

```rust
// fetch_orchestration_item: 6-7 queries
1. SELECT q.instance_id ... FOR UPDATE SKIP LOCKED
2. INSERT INTO instance_locks ... ON CONFLICT DO UPDATE
3. UPDATE orchestrator_queue SET lock_token = ...
4. SELECT id, work_item FROM orchestrator_queue WHERE lock_token = ?
5. SELECT orchestration_name, version FROM instances WHERE instance_id = ?
6. SELECT event_data FROM history WHERE instance_id = ? (fallback)
7. COMMIT

// ack_orchestration_item: 8-9 queries
1. SELECT instance_id FROM instance_locks WHERE lock_token = ?
2. INSERT INTO instances ... ON CONFLICT DO NOTHING
3. UPDATE instances SET orchestration_name = ?, version = ?
4. INSERT INTO executions ... ON CONFLICT DO NOTHING
5. UPDATE instances SET current_execution_id = ...
6. INSERT INTO history (loop for each event)
7. UPDATE executions SET status = ?, output = ?
8. DELETE FROM orchestrator_queue WHERE lock_token = ?
9. DELETE FROM instance_locks WHERE instance_id = ?
10. COMMIT
```

### Target State

**Stored procedures with 2 queries per turn:**

```rust
// fetch_orchestration_item: 1 query
let result = sqlx::query_as(&format!(
    "SELECT * FROM {}.sp_fetch_orchestration_item($1, $2)",
    self.schema_name
))
.bind(now_ms)
.bind(lock_timeout_ms)
.fetch_optional(&*self.pool)
.await?;

// ack_orchestration_item: 1 query
sqlx::query(&format!(
    "SELECT {}.sp_ack_orchestration_item($1, $2, $3, $4, $5, $6)",
    self.schema_name
))
.bind(lock_token)
.bind(execution_id)
.bind(history_delta_json)
.bind(worker_items_json)
.bind(orchestrator_items_json)
.bind(metadata_json)
.execute(&*self.pool)
.await?;
```

**Result:**
- **Query count:** 15-16 → 2 (87% reduction)
- **Network roundtrips:** ~3,900ms → ~400ms (90% reduction)
- **Throughput:** ~15 turns/min → ~150 turns/min (10× improvement)

