-- Migration: 0007_add_execution_state_to_work_items.sql
-- Description: Updates fetch_work_item and renew_work_item_lock to return ExecutionState
-- Required for duroxide 0.1.7 activity cancellation support
--
-- ExecutionState can be:
-- - "Running" - orchestration is active, activity should proceed
-- - "Completed", "Failed", "ContinuedAsNew" - terminal states, activity result won't be observed
-- - "Missing" - instance or execution deleted, activity should abort

DO $$
DECLARE
    v_schema_name TEXT := current_schema();
BEGIN
    -- ============================================================================
    -- Update fetch_work_item to return ExecutionState (4th column)
    -- ============================================================================
    EXECUTE format('DROP FUNCTION IF EXISTS %I.fetch_work_item(BIGINT, BIGINT)', v_schema_name);

    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.fetch_work_item(
            p_now_ms BIGINT,
            p_lock_timeout_ms BIGINT
        )
        RETURNS TABLE(
            out_work_item TEXT,
            out_lock_token TEXT,
            out_attempt_count INTEGER,
            out_execution_state TEXT
        ) AS $fetch_worker$
        DECLARE
            v_id BIGINT;
            v_instance_id TEXT;
            v_execution_id BIGINT;
            v_execution_status TEXT;
            v_instance_exists BOOLEAN;
        BEGIN
            -- Item is available if:
            -- 1. visible_at <= now (not delayed)
            -- 2. AND (lock_token IS NULL OR locked_until <= now) (not locked or lock expired)
            SELECT q.id, q.work_item INTO v_id, out_work_item
            FROM %I.worker_queue q
            WHERE q.visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
              AND (q.lock_token IS NULL OR q.locked_until <= p_now_ms)
            ORDER BY q.id
            LIMIT 1
            FOR UPDATE OF q SKIP LOCKED;

            IF NOT FOUND THEN
                RETURN;
            END IF;

            out_lock_token := ''lock_'' || gen_random_uuid()::TEXT;

            -- Increment attempt_count and lock the item
            UPDATE %I.worker_queue
            SET lock_token = out_lock_token,
                locked_until = p_now_ms + p_lock_timeout_ms,
                attempt_count = attempt_count + 1
            WHERE id = v_id;

            SELECT work_item, attempt_count
            INTO out_work_item, out_attempt_count
            FROM %I.worker_queue
            WHERE id = v_id;

            -- Extract instance_id and execution_id from the work item JSON
            -- Different work item types store these in different locations
            v_instance_id := NULL;
            v_execution_id := NULL;
            
            -- Try to extract based on work item type
            BEGIN
                -- ActivityExecute: {"ActivityExecute":{"instance":"...","execution_id":...}}
                IF out_work_item::JSONB ? ''ActivityExecute'' THEN
                    v_instance_id := out_work_item::JSONB->''ActivityExecute''->>''instance'';
                    v_execution_id := (out_work_item::JSONB->''ActivityExecute''->>''execution_id'')::BIGINT;
                
                -- ActivityCompleted: {"ActivityCompleted":{"instance":"...","execution_id":...}}
                ELSIF out_work_item::JSONB ? ''ActivityCompleted'' THEN
                    v_instance_id := out_work_item::JSONB->''ActivityCompleted''->>''instance'';
                    v_execution_id := (out_work_item::JSONB->''ActivityCompleted''->>''execution_id'')::BIGINT;
                
                -- ActivityFailed: {"ActivityFailed":{"instance":"...","execution_id":...}}
                ELSIF out_work_item::JSONB ? ''ActivityFailed'' THEN
                    v_instance_id := out_work_item::JSONB->''ActivityFailed''->>''instance'';
                    v_execution_id := (out_work_item::JSONB->''ActivityFailed''->>''execution_id'')::BIGINT;
                
                -- StartOrchestration: {"StartOrchestration":{"instance":"...","execution_id":...}}
                ELSIF out_work_item::JSONB ? ''StartOrchestration'' THEN
                    v_instance_id := out_work_item::JSONB->''StartOrchestration''->>''instance'';
                    v_execution_id := (out_work_item::JSONB->''StartOrchestration''->>''execution_id'')::BIGINT;
                
                -- TimerFired: {"TimerFired":{"instance":"...","execution_id":...}}
                ELSIF out_work_item::JSONB ? ''TimerFired'' THEN
                    v_instance_id := out_work_item::JSONB->''TimerFired''->>''instance'';
                    v_execution_id := (out_work_item::JSONB->''TimerFired''->>''execution_id'')::BIGINT;
                
                -- ExternalRaised: {"ExternalRaised":{"instance":"...","execution_id":...}}
                ELSIF out_work_item::JSONB ? ''ExternalRaised'' THEN
                    v_instance_id := out_work_item::JSONB->''ExternalRaised''->>''instance'';
                    v_execution_id := (out_work_item::JSONB->''ExternalRaised''->>''execution_id'')::BIGINT;
                
                -- CancelInstance: {"CancelInstance":{"instance":"...","execution_id":...}}
                ELSIF out_work_item::JSONB ? ''CancelInstance'' THEN
                    v_instance_id := out_work_item::JSONB->''CancelInstance''->>''instance'';
                    v_execution_id := (out_work_item::JSONB->''CancelInstance''->>''execution_id'')::BIGINT;
                
                -- ContinueAsNew: {"ContinueAsNew":{"instance":"...","execution_id":...}}
                ELSIF out_work_item::JSONB ? ''ContinueAsNew'' THEN
                    v_instance_id := out_work_item::JSONB->''ContinueAsNew''->>''instance'';
                    v_execution_id := (out_work_item::JSONB->''ContinueAsNew''->>''execution_id'')::BIGINT;
                
                -- SubOrchCompleted: {"SubOrchCompleted":{"parent_instance":"...","parent_execution_id":...}}
                ELSIF out_work_item::JSONB ? ''SubOrchCompleted'' THEN
                    v_instance_id := out_work_item::JSONB->''SubOrchCompleted''->>''parent_instance'';
                    v_execution_id := (out_work_item::JSONB->''SubOrchCompleted''->>''parent_execution_id'')::BIGINT;
                
                -- SubOrchFailed: {"SubOrchFailed":{"parent_instance":"...","parent_execution_id":...}}
                ELSIF out_work_item::JSONB ? ''SubOrchFailed'' THEN
                    v_instance_id := out_work_item::JSONB->''SubOrchFailed''->>''parent_instance'';
                    v_execution_id := (out_work_item::JSONB->''SubOrchFailed''->>''parent_execution_id'')::BIGINT;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    -- If extraction fails, we''ll default to Missing state
                    v_instance_id := NULL;
            END;

            -- Determine ExecutionState based on instance and execution existence
            IF v_instance_id IS NULL OR v_execution_id IS NULL THEN
                -- Cannot determine state without instance/execution info
                out_execution_state := ''Missing'';
            ELSE
                -- Check if instance exists
                SELECT EXISTS(SELECT 1 FROM %I.instances WHERE instance_id = v_instance_id)
                INTO v_instance_exists;

                IF NOT v_instance_exists THEN
                    out_execution_state := ''Missing'';
                ELSE
                    -- Get execution status
                    SELECT status INTO v_execution_status
                    FROM %I.executions
                    WHERE instance_id = v_instance_id AND execution_id = v_execution_id;

                    IF NOT FOUND THEN
                        out_execution_state := ''Missing'';
                    ELSIF v_execution_status = ''Running'' THEN
                        out_execution_state := ''Running'';
                    ELSE
                        -- Terminal states: Completed, Failed, ContinuedAsNew
                        out_execution_state := v_execution_status;
                    END IF;
                END IF;
            END IF;

            RETURN NEXT;
        END;
        $fetch_worker$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name);

    -- ============================================================================
    -- Update renew_work_item_lock to return ExecutionState
    -- ============================================================================
    EXECUTE format('DROP FUNCTION IF EXISTS %I.renew_work_item_lock(TEXT, BIGINT, BIGINT)', v_schema_name);

    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.renew_work_item_lock(
            p_lock_token TEXT,
            p_now_ms BIGINT,
            p_extend_secs BIGINT
        )
        RETURNS TEXT AS $renew_lock$
        DECLARE
            v_locked_until BIGINT;
            v_rows_affected INTEGER;
            v_work_item TEXT;
            v_instance_id TEXT;
            v_execution_id BIGINT;
            v_execution_status TEXT;
            v_instance_exists BOOLEAN;
        BEGIN
            -- Calculate new locked_until timestamp
            v_locked_until := p_now_ms + (p_extend_secs * 1000);
            
            -- Update lock timeout only if lock is still valid
            -- Use p_now_ms (from application) for consistent time reference
            UPDATE %I.worker_queue
            SET locked_until = v_locked_until
            WHERE lock_token = p_lock_token
              AND locked_until > p_now_ms
            RETURNING work_item INTO v_work_item;
            
            GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
            
            IF v_rows_affected = 0 THEN
                RAISE EXCEPTION ''Lock token invalid, expired, or already acked'';
            END IF;

            -- Extract instance_id and execution_id from the work item JSON
            v_instance_id := NULL;
            v_execution_id := NULL;
            
            -- Try to extract based on work item type
            BEGIN
                -- ActivityExecute: {"ActivityExecute":{"instance":"...","execution_id":...}}
                IF v_work_item::JSONB ? ''ActivityExecute'' THEN
                    v_instance_id := v_work_item::JSONB->''ActivityExecute''->>''instance'';
                    v_execution_id := (v_work_item::JSONB->''ActivityExecute''->>''execution_id'')::BIGINT;
                
                -- ActivityCompleted: {"ActivityCompleted":{"instance":"...","execution_id":...}}
                ELSIF v_work_item::JSONB ? ''ActivityCompleted'' THEN
                    v_instance_id := v_work_item::JSONB->''ActivityCompleted''->>''instance'';
                    v_execution_id := (v_work_item::JSONB->''ActivityCompleted''->>''execution_id'')::BIGINT;
                
                -- ActivityFailed: {"ActivityFailed":{"instance":"...","execution_id":...}}
                ELSIF v_work_item::JSONB ? ''ActivityFailed'' THEN
                    v_instance_id := v_work_item::JSONB->''ActivityFailed''->>''instance'';
                    v_execution_id := (v_work_item::JSONB->''ActivityFailed''->>''execution_id'')::BIGINT;
                
                -- StartOrchestration: {"StartOrchestration":{"instance":"...","execution_id":...}}
                ELSIF v_work_item::JSONB ? ''StartOrchestration'' THEN
                    v_instance_id := v_work_item::JSONB->''StartOrchestration''->>''instance'';
                    v_execution_id := (v_work_item::JSONB->''StartOrchestration''->>''execution_id'')::BIGINT;
                
                -- TimerFired: {"TimerFired":{"instance":"...","execution_id":...}}
                ELSIF v_work_item::JSONB ? ''TimerFired'' THEN
                    v_instance_id := v_work_item::JSONB->''TimerFired''->>''instance'';
                    v_execution_id := (v_work_item::JSONB->''TimerFired''->>''execution_id'')::BIGINT;
                
                -- ExternalRaised: {"ExternalRaised":{"instance":"...","execution_id":...}}
                ELSIF v_work_item::JSONB ? ''ExternalRaised'' THEN
                    v_instance_id := v_work_item::JSONB->''ExternalRaised''->>''instance'';
                    v_execution_id := (v_work_item::JSONB->''ExternalRaised''->>''execution_id'')::BIGINT;
                
                -- CancelInstance: {"CancelInstance":{"instance":"...","execution_id":...}}
                ELSIF v_work_item::JSONB ? ''CancelInstance'' THEN
                    v_instance_id := v_work_item::JSONB->''CancelInstance''->>''instance'';
                    v_execution_id := (v_work_item::JSONB->''CancelInstance''->>''execution_id'')::BIGINT;
                
                -- ContinueAsNew: {"ContinueAsNew":{"instance":"...","execution_id":...}}
                ELSIF v_work_item::JSONB ? ''ContinueAsNew'' THEN
                    v_instance_id := v_work_item::JSONB->''ContinueAsNew''->>''instance'';
                    v_execution_id := (v_work_item::JSONB->''ContinueAsNew''->>''execution_id'')::BIGINT;
                
                -- SubOrchCompleted: {"SubOrchCompleted":{"parent_instance":"...","parent_execution_id":...}}
                ELSIF v_work_item::JSONB ? ''SubOrchCompleted'' THEN
                    v_instance_id := v_work_item::JSONB->''SubOrchCompleted''->>''parent_instance'';
                    v_execution_id := (v_work_item::JSONB->''SubOrchCompleted''->>''parent_execution_id'')::BIGINT;
                
                -- SubOrchFailed: {"SubOrchFailed":{"parent_instance":"...","parent_execution_id":...}}
                ELSIF v_work_item::JSONB ? ''SubOrchFailed'' THEN
                    v_instance_id := v_work_item::JSONB->''SubOrchFailed''->>''parent_instance'';
                    v_execution_id := (v_work_item::JSONB->''SubOrchFailed''->>''parent_execution_id'')::BIGINT;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    -- If extraction fails, we''ll default to Missing state
                    v_instance_id := NULL;
            END;

            -- Determine ExecutionState based on instance and execution existence
            IF v_instance_id IS NULL OR v_execution_id IS NULL THEN
                -- Cannot determine state without instance/execution info
                RETURN ''Missing'';
            ELSE
                -- Check if instance exists
                SELECT EXISTS(SELECT 1 FROM %I.instances WHERE instance_id = v_instance_id)
                INTO v_instance_exists;

                IF NOT v_instance_exists THEN
                    RETURN ''Missing'';
                ELSE
                    -- Get execution status
                    SELECT status INTO v_execution_status
                    FROM %I.executions
                    WHERE instance_id = v_instance_id AND execution_id = v_execution_id;

                    IF NOT FOUND THEN
                        RETURN ''Missing'';
                    ELSIF v_execution_status = ''Running'' THEN
                        RETURN ''Running'';
                    ELSE
                        -- Terminal states: Completed, Failed, ContinuedAsNew
                        RETURN v_execution_status;
                    END IF;
                END IF;
            END IF;
        END;
        $renew_lock$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name, v_schema_name);

END $$;
