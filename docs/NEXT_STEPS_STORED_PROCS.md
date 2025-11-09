# Next Steps: Stored Procedure Implementation

**Priority:** HIGH - Critical Path Optimization  
**Timeline:** 3-5 days  
**Expected ROI:** 10× performance improvement on remote database

---

## Goal

Implement stored procedures for the two most impactful operations:
1. `sp_fetch_orchestration_item()` - Saves ~2,000ms per call
2. `sp_ack_orchestration_item()` - Saves ~1,500ms per call

**Combined impact:** Reduce turn time from 3.9s → 0.4s (10× improvement)

---

## Implementation Steps

### Step 1: Implement `sp_fetch_orchestration_item`

**Estimated time:** 1-2 days

#### 1.1 Add Procedure to Migration

Edit `migrations/0002_create_stored_procedures.sql`:

```sql
-- Add after existing procedures, before END $$;

-- Procedure: fetch_orchestration_item
-- Fetches and locks an orchestration item in a single database roundtrip
EXECUTE format('
    CREATE OR REPLACE FUNCTION %I.fetch_orchestration_item(
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
    ) AS $fetch_orch$
    DECLARE
        v_instance_id TEXT;
        v_lock_token TEXT;
        v_locked_until BIGINT;
        v_orchestration_name TEXT;
        v_orchestration_version TEXT;
        v_current_execution_id BIGINT;
        v_history JSONB;
        v_messages JSONB;
        v_lock_acquired BOOLEAN;
    BEGIN
        -- Step 1: Find available instance
        SELECT q.instance_id INTO v_instance_id
        FROM %I.orchestrator_queue q
        WHERE q.visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
          AND NOT EXISTS (
            SELECT 1 FROM %I.instance_locks il
            WHERE il.instance_id = q.instance_id AND il.locked_until > p_now_ms
          )
        ORDER BY q.visible_at, q.id
        LIMIT 1
        FOR UPDATE SKIP LOCKED;

        IF NOT FOUND THEN
            RETURN; -- No available instances
        END IF;

        -- Step 2: Generate lock token and acquire instance lock
        v_lock_token := ''lock_'' || gen_random_uuid()::TEXT;
        v_locked_until := p_now_ms + p_lock_timeout_ms;

        INSERT INTO %I.instance_locks (instance_id, lock_token, locked_until, locked_at)
        VALUES (v_instance_id, v_lock_token, v_locked_until, p_now_ms)
        ON CONFLICT(instance_id) DO UPDATE
        SET lock_token = EXCLUDED.lock_token,
            locked_until = EXCLUDED.locked_until,
            locked_at = EXCLUDED.locked_at
        WHERE %I.instance_locks.locked_until <= p_now_ms;

        GET DIAGNOSTICS v_lock_acquired = ROW_COUNT;

        IF v_lock_acquired = 0 THEN
            RETURN; -- Failed to acquire lock
        END IF;

        -- Step 3: Mark all visible messages for this instance with our lock
        UPDATE %I.orchestrator_queue
        SET lock_token = v_lock_token,
            locked_until = v_locked_until
        WHERE instance_id = v_instance_id
          AND visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
          AND (lock_token IS NULL OR locked_until <= p_now_ms);

        -- Step 4: Fetch all locked messages as JSONB array
        SELECT COALESCE(JSONB_AGG(work_item::JSONB ORDER BY id), ''[]''::JSONB)
        INTO v_messages
        FROM %I.orchestrator_queue
        WHERE lock_token = v_lock_token;

        -- Step 5: Load instance metadata (if exists)
        SELECT orchestration_name, orchestration_version, current_execution_id
        INTO v_orchestration_name, v_orchestration_version, v_current_execution_id
        FROM %I.instances
        WHERE instance_id = v_instance_id;

        -- Step 6: Load history or implement fallback
        IF FOUND THEN
            -- Instance exists, load its history for current execution
            SELECT COALESCE(JSONB_AGG(event_data::JSONB ORDER BY event_id), ''[]''::JSONB)
            INTO v_history
            FROM %I.history
            WHERE instance_id = v_instance_id AND execution_id = v_current_execution_id;
            
            v_orchestration_version := COALESCE(v_orchestration_version, ''unknown'');
        ELSE
            -- Fallback: instance doesn''t exist, try to extract from history
            SELECT COALESCE(JSONB_AGG(event_data::JSONB ORDER BY execution_id, event_id), ''[]''::JSONB)
            INTO v_history
            FROM %I.history
            WHERE instance_id = v_instance_id;

            -- Try to extract metadata from history
            IF JSONB_ARRAY_LENGTH(v_history) > 0 AND v_history->0->''OrchestrationStarted'' IS NOT NULL THEN
                v_orchestration_name := v_history->0->''OrchestrationStarted''->''name'';
                v_orchestration_version := v_history->0->''OrchestrationStarted''->''version'';
                v_current_execution_id := 1;
            ELSE
                -- Extract from messages (StartOrchestration work item)
                v_orchestration_name := v_messages->0->''orchestration'';
                v_orchestration_version := COALESCE(v_messages->0->''version'', ''unknown'');
                v_current_execution_id := COALESCE((v_messages->0->''execution_id'')::BIGINT, 1);
            END IF;
            
            -- Use defaults if still NULL
            v_orchestration_name := COALESCE(v_orchestration_name, ''Unknown'');
            v_orchestration_version := COALESCE(v_orchestration_version, ''unknown'');
            v_current_execution_id := COALESCE(v_current_execution_id, 1);
        END IF;

        -- Return single row with all data
        RETURN QUERY SELECT
            v_instance_id,
            v_orchestration_name,
            v_orchestration_version,
            v_current_execution_id,
            v_history,
            v_messages,
            v_lock_token;
    END;
    $fetch_orch$ LANGUAGE plpgsql;
', v_schema_name, v_schema_name, v_schema_name, v_schema_name, 
   v_schema_name, v_schema_name, v_schema_name, v_schema_name, 
   v_schema_name, v_schema_name, v_schema_name);
```

#### 1.2 Update Rust Code

Edit `src/provider.rs` - `fetch_orchestration_item` method:

```rust
async fn fetch_orchestration_item(&self) -> Result<Option<OrchestrationItem>, ProviderError> {
    let start = std::time::Instant::now();
    let now_ms = Self::now_millis();

    // Retry loop (keep in Rust for flexibility)
    const MAX_RETRIES: u32 = 3;
    const RETRY_DELAY_MS: u64 = 10;

    for attempt in 0..=MAX_RETRIES {
        // Call stored procedure
        let row: Option<(String, String, String, i64, serde_json::Value, serde_json::Value, String)> =
            sqlx::query_as(&format!(
                "SELECT * FROM {}.fetch_orchestration_item($1, $2)",
                self.schema_name
            ))
            .bind(now_ms)
            .bind(self.lock_timeout_ms as i64)
            .fetch_optional(&*self.pool)
            .await
            .map_err(|e| Self::sqlx_to_provider_error("fetch_orchestration_item", e))?;

        if let Some((instance_id, orchestration_name, orchestration_version, execution_id, history_json, messages_json, lock_token)) = row {
            // Deserialize JSONB arrays
            let history: Vec<Event> = serde_json::from_value(history_json)
                .map_err(|e| ProviderError::permanent("fetch_orchestration_item", &format!("Failed to deserialize history: {}", e)))?;
            
            let messages: Vec<WorkItem> = serde_json::from_value(messages_json)
                .map_err(|e| ProviderError::permanent("fetch_orchestration_item", &format!("Failed to deserialize messages: {}", e)))?;

            let duration_ms = start.elapsed().as_millis() as u64;
            debug!(
                target = "duroxide::providers::postgres",
                operation = "fetch_orchestration_item",
                instance_id = %instance_id,
                execution_id = execution_id,
                message_count = messages.len(),
                history_count = history.len(),
                duration_ms = duration_ms,
                attempts = attempt + 1,
                "Fetched orchestration item via stored procedure"
            );

            return Ok(Some(OrchestrationItem {
                instance: instance_id,
                orchestration_name,
                execution_id: execution_id as u64,
                version: orchestration_version,
                history,
                messages,
                lock_token,
            }));
        }

        // No available instances, retry with backoff
        if attempt < MAX_RETRIES {
            sleep(Duration::from_millis(RETRY_DELAY_MS)).await;
        }
    }

    Ok(None)
}
```

#### 1.3 Test

```bash
# Run basic tests
cargo test --lib --test basic_tests test_enqueue_for_orchestrator -- --nocapture

# Run validation tests
cargo test --test postgres_provider_test instance_creation_tests

# Benchmark performance
time cargo test --lib --test basic_tests
```

**Expected:**
- All tests pass
- `fetch_orchestration_item` time: ~2,200ms → ~200ms
- Debug log shows single query with stored procedure name

---

### Step 2: Implement `sp_ack_orchestration_item`

**Estimated time:** 1-2 days

#### 2.1 Add Procedure to Migration

```sql
-- Procedure: ack_orchestration_item
-- Acknowledges orchestration item in a single atomic operation
EXECUTE format('
    CREATE OR REPLACE FUNCTION %I.ack_orchestration_item(
        p_lock_token TEXT,
        p_execution_id BIGINT,
        p_history_delta JSONB,
        p_worker_items JSONB,
        p_orchestrator_items JSONB,
        p_metadata JSONB
    )
    RETURNS VOID AS $ack_orch$
    DECLARE
        v_instance_id TEXT;
        v_now_ms BIGINT;
        v_orchestration_name TEXT;
        v_orchestration_version TEXT;
        v_status TEXT;
        v_output TEXT;
        v_completed_at TIMESTAMPTZ;
        v_elem JSONB;
        v_visible_at TIMESTAMPTZ;
        v_fire_at_ms BIGINT;
    BEGIN
        v_now_ms := (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT;

        -- Step 1: Validate lock token
        SELECT instance_id INTO v_instance_id
        FROM %I.instance_locks
        WHERE lock_token = p_lock_token AND locked_until > v_now_ms;

        IF NOT FOUND THEN
            RAISE EXCEPTION ''Invalid lock token'';
        END IF;

        -- Step 2: Extract metadata
        v_orchestration_name := p_metadata->>''orchestration_name'';
        v_orchestration_version := p_metadata->>''orchestration_version'';
        v_status := p_metadata->>''status'';
        v_output := p_metadata->>''output'';

        -- Step 3: Create or update instance metadata
        IF v_orchestration_name IS NOT NULL AND v_orchestration_version IS NOT NULL THEN
            INSERT INTO %I.instances (instance_id, orchestration_name, orchestration_version, current_execution_id)
            VALUES (v_instance_id, v_orchestration_name, v_orchestration_version, p_execution_id)
            ON CONFLICT (instance_id) DO NOTHING;

            UPDATE %I.instances
            SET orchestration_name = v_orchestration_name,
                orchestration_version = v_orchestration_version
            WHERE instance_id = v_instance_id;
        END IF;

        -- Step 4: Create execution record (idempotent)
        INSERT INTO %I.executions (instance_id, execution_id, status, started_at)
        VALUES (v_instance_id, p_execution_id, ''Running'', NOW())
        ON CONFLICT (instance_id, execution_id) DO NOTHING;

        -- Step 5: Update instance current_execution_id
        UPDATE %I.instances
        SET current_execution_id = GREATEST(current_execution_id, p_execution_id)
        WHERE instance_id = v_instance_id;

        -- Step 6: Append history_delta (batch insert)
        IF p_history_delta IS NOT NULL AND JSONB_ARRAY_LENGTH(p_history_delta) > 0 THEN
            INSERT INTO %I.history (instance_id, execution_id, event_id, event_type, event_data)
            SELECT
                v_instance_id,
                p_execution_id,
                (elem->>''event_id'')::BIGINT,
                elem->>''event_type'',
                elem::TEXT
            FROM JSONB_ARRAY_ELEMENTS(p_history_delta) AS elem;
        END IF;

        -- Step 7: Update execution status if provided
        IF v_status IS NOT NULL THEN
            v_completed_at := CASE 
                WHEN v_status IN (''Completed'', ''Failed'') THEN NOW() 
                ELSE NULL 
            END;
            
            UPDATE %I.executions
            SET status = v_status, output = v_output, completed_at = v_completed_at
            WHERE instance_id = v_instance_id AND execution_id = p_execution_id;
        END IF;

        -- Step 8: Enqueue worker items (batch)
        IF p_worker_items IS NOT NULL AND JSONB_ARRAY_LENGTH(p_worker_items) > 0 THEN
            INSERT INTO %I.worker_queue (work_item, created_at)
            SELECT elem::TEXT, NOW()
            FROM JSONB_ARRAY_ELEMENTS(p_worker_items) AS elem;
        END IF;

        -- Step 9: Enqueue orchestrator items (batch with visible_at handling)
        IF p_orchestrator_items IS NOT NULL AND JSONB_ARRAY_LENGTH(p_orchestrator_items) > 0 THEN
            FOR v_elem IN SELECT value FROM JSONB_ARRAY_ELEMENTS(p_orchestrator_items) LOOP
                -- Extract instance from work item
                -- (Simplified: assume instance is in work item, extract in Rust if complex)
                
                -- Handle TimerFired special case for visible_at
                v_fire_at_ms := (v_elem->>''fire_at_ms'')::BIGINT;
                v_visible_at := CASE
                    WHEN v_fire_at_ms IS NOT NULL AND v_fire_at_ms > 0 THEN
                        TO_TIMESTAMP(v_fire_at_ms / 1000.0)
                    ELSE
                        NOW()
                END;

                INSERT INTO %I.orchestrator_queue (instance_id, work_item, visible_at, created_at)
                VALUES (
                    v_instance_id,  -- Note: may need to extract from v_elem
                    v_elem::TEXT,
                    v_visible_at,
                    NOW()
                );
            END LOOP;
        END IF;

        -- Step 10: Delete locked messages
        DELETE FROM %I.orchestrator_queue WHERE lock_token = p_lock_token;

        -- Step 11: Remove instance lock
        DELETE FROM %I.instance_locks
        WHERE instance_id = v_instance_id AND lock_token = p_lock_token;
    END;
    $ack_orch$ LANGUAGE plpgsql;
', v_schema_name, v_schema_name, v_schema_name, v_schema_name, 
   v_schema_name, v_schema_name, v_schema_name, v_schema_name,
   v_schema_name, v_schema_name, v_schema_name, v_schema_name);
```

#### 2.2 Update Rust Code

Edit `src/provider.rs` - `ack_orchestration_item` method:

```rust
async fn ack_orchestration_item(
    &self,
    lock_token: &str,
    execution_id: u64,
    history_delta: Vec<Event>,
    worker_items: Vec<WorkItem>,
    orchestrator_items: Vec<WorkItem>,
    metadata: ExecutionMetadata,
) -> Result<(), ProviderError> {
    let start = std::time::Instant::now();

    // Serialize data to JSONB
    let history_delta_json = serde_json::to_value(&history_delta)
        .map_err(|e| ProviderError::permanent("ack_orchestration_item", &format!("Failed to serialize history: {}", e)))?;
    
    let worker_items_json = serde_json::to_value(&worker_items)
        .map_err(|e| ProviderError::permanent("ack_orchestration_item", &format!("Failed to serialize worker items: {}", e)))?;
    
    let orchestrator_items_json = serde_json::to_value(&orchestrator_items)
        .map_err(|e| ProviderError::permanent("ack_orchestration_item", &format!("Failed to serialize orchestrator items: {}", e)))?;
    
    let metadata_json = serde_json::json!({
        "orchestration_name": metadata.orchestration_name,
        "orchestration_version": metadata.orchestration_version,
        "status": metadata.status,
        "output": metadata.output,
    });

    // Call stored procedure
    sqlx::query(&format!(
        "SELECT {}.ack_orchestration_item($1, $2, $3, $4, $5, $6)",
        self.schema_name
    ))
    .bind(lock_token)
    .bind(execution_id as i64)
    .bind(history_delta_json)
    .bind(worker_items_json)
    .bind(orchestrator_items_json)
    .bind(metadata_json)
    .execute(&*self.pool)
    .await
    .map_err(|e| {
        if e.to_string().contains("Invalid lock token") {
            ProviderError::permanent("ack_orchestration_item", "Invalid lock token")
        } else {
            Self::sqlx_to_provider_error("ack_orchestration_item", e)
        }
    })?;

    let duration_ms = start.elapsed().as_millis() as u64;
    debug!(
        target = "duroxide::providers::postgres",
        operation = "ack_orchestration_item",
        execution_id = execution_id,
        history_count = history_delta.len(),
        worker_items_count = worker_items.len(),
        orchestrator_items_count = orchestrator_items.len(),
        duration_ms = duration_ms,
        "Acknowledged orchestration item via stored procedure"
    );

    Ok(())
}
```

#### 2.3 Test

```bash
# Run all tests
cargo test

# Check performance with debug output
cargo test --lib --test basic_tests test_enqueue_for_orchestrator -- --nocapture | grep duration_ms
```

---

## Simplified Approach: Pre-extract Instance IDs

To simplify the stored procedures, extract complex data in Rust before calling:

### For `ack_orchestration_item`:

**Pre-process in Rust:**
```rust
// Extract instance IDs from orchestrator items
let orchestrator_items_with_instances: Vec<(String, WorkItem)> = orchestrator_items
    .into_iter()
    .map(|item| {
        let instance = match &item {
            WorkItem::StartOrchestration { instance, .. } => instance,
            WorkItem::TimerFired { instance, .. } => instance,
            // ... other variants
        }.clone();
        (instance, item)
    })
    .collect();
```

**Pass to procedure:**
```sql
CREATE FUNCTION ack_orchestration_item(
    ...
    p_orchestrator_items_with_instances JSONB  -- [{"instance": "...", "item": {...}}, ...]
)
```

**In procedure:**
```sql
INSERT INTO orchestrator_queue (instance_id, work_item, visible_at, created_at)
SELECT
    elem->>'instance',
    (elem->'item')::TEXT,
    CASE 
        WHEN (elem->'item'->>'fire_at_ms')::BIGINT > 0 
        THEN TO_TIMESTAMP((elem->'item'->>'fire_at_ms')::BIGINT / 1000.0)
        ELSE NOW()
    END,
    NOW()
FROM JSONB_ARRAY_ELEMENTS(p_orchestrator_items_with_instances) AS elem;
```

---

## Testing Checklist

### Per Procedure

- [ ] Unit test: Call procedure directly via SQL
- [ ] Integration test: Call via Rust Provider
- [ ] Concurrency test: Multiple workers
- [ ] Error handling: Invalid inputs, exceptions
- [ ] Edge cases: Empty results, NULL values
- [ ] Performance: Measure query time
- [ ] Validation tests: All 45 tests pass
- [ ] E2E tests: All 25 tests pass

### Full Migration

- [ ] All 79 tests pass
- [ ] Performance improved 8-10×
- [ ] No behavioral changes
- [ ] Debug logging shows stored procedure calls

---

## Risk Mitigation

### Keep Old Code Temporarily

```rust
#[cfg(feature = "use-stored-procs")]
async fn fetch_orchestration_item(&self) -> Result<Option<OrchestrationItem>, ProviderError> {
    // New: stored procedure implementation
}

#[cfg(not(feature = "use-stored-procs"))]
async fn fetch_orchestration_item(&self) -> Result<Option<OrchestrationItem>, ProviderError> {
    // Old: inline SQL implementation
}
```

### Gradual Rollout

1. Implement with feature flag disabled by default
2. Test thoroughly
3. Enable feature flag
4. Monitor production
5. Remove old code after confidence

---

## Expected Results

### Before (Current State)

```
DEBUG fetch_orchestration_item: duration_ms=2181 attempts=1
  - 7 queries × ~180ms each = ~1,260ms
  - Transaction overhead = ~900ms

DEBUG ack_orchestration_item: duration_ms=1709
  - 9 queries × ~170ms each = ~1,530ms
  - Transaction overhead = ~180ms

Total turn time: ~3,900ms
```

### After (With Stored Procedures)

```
DEBUG fetch_orchestration_item: duration_ms=200 attempts=1
  - 1 stored procedure call = ~200ms

DEBUG ack_orchestration_item: duration_ms=180
  - 1 stored procedure call = ~180ms

Total turn time: ~380ms
```

**Improvement:** 10.3× faster (3,900ms → 380ms)

---

## Alternative: Use JSONB for All Complex Types

### Simplified Approach

Instead of parsing complex structures in SQL, pass pre-serialized JSONB:

**Rust side:**
```rust
let history_json = serde_json::to_value(&history_delta)?;
let worker_json = serde_json::to_value(&worker_items)?;
let orch_json = serde_json::to_value(&orchestrator_items)?;
```

**SQL side:**
```sql
-- Store as-is, no parsing needed
INSERT INTO history (instance_id, execution_id, event_id, event_type, event_data)
SELECT 
    v_instance_id,
    p_execution_id,
    (elem->>'event_id')::BIGINT,
    elem->>'event_type',
    elem::TEXT
FROM JSONB_ARRAY_ELEMENTS(p_history_delta) AS elem;
```

**Benefit:** Simpler SQL, less error-prone, faster development

---

## Next Action

**Start with `sp_fetch_orchestration_item`:**
1. Add procedure to `migrations/0002_create_stored_procedures.sql`
2. Update Rust code in `src/provider.rs`
3. Run tests to verify
4. Measure performance improvement

**Then continue with `sp_ack_orchestration_item`.**

After these two are done, you'll have achieved 90% of the potential performance improvement!

