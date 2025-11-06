# Stored Procedure Migration - Executive Summary

## Overview

Convert all inline SQL queries in `src/provider.rs` (~70 queries) to PostgreSQL stored procedures for improved maintainability, performance, and security.

## Key Statistics

- **Total SQL queries**: ~70
- **Methods with SQL**: 27
- **Estimated procedures needed**: ~20
- **Estimated timeline**: 3-4 weeks
- **Risk level**: Medium-High (due to complexity of core orchestration operations)

## Migration Approach

### Incremental, Priority-Based Migration

1. Start with simple SELECT queries (low risk, quick wins)
2. Progress to JOIN and aggregate queries
3. Handle simple writes and queue operations
4. Finally tackle complex orchestration transactions

### Schema Handling

- Procedures created per schema (supports custom schemas)
- Schema-qualified procedure names: `{schema}.sp_{operation}_{entity}`
- Helper function to create procedures in target schema

## Priority Breakdown

### 🔵 Low Risk (Start Here)
- Simple SELECT queries (5 procedures)
- Estimated time: 2-3 days

### 🟡 Medium Risk
- JOIN queries (3 procedures)
- Aggregate queries (2 procedures)
- Simple writes (3 procedures)
- Estimated time: 5-7 days

### 🔴 High Risk (Requires Careful Testing)
- Queue operations (3 procedures)
- Core orchestration (3 procedures)
- Estimated time: 8-10 days

### ⚪ Special Case
- Schema management (2 procedures)
- Estimated time: 2-3 days

## Quick Start Guide

### Step 1: Create Migration File
```bash
touch migrations/0002_create_stored_procedures.sql
```

### Step 2: Start with First Procedure
Convert `list_instances()` - a simple SELECT query.

### Step 3: Test Incrementally
After each procedure:
1. Create procedure in migration
2. Update Rust code
3. Run tests
4. Verify behavior

### Step 4: Continue Priority Order
Follow the priority order in `STORED_PROCEDURE_ACTION_PLAN.md`

## Example Conversion

### SQL Query (Before)
```rust
sqlx::query_scalar(&format!(
    "SELECT instance_id FROM {} ORDER BY created_at DESC",
    self.table_name("instances")
))
.fetch_all(&*self.pool)
```

### Stored Procedure (After)
```sql
CREATE OR REPLACE FUNCTION {schema}.sp_list_instances()
RETURNS TABLE(instance_id TEXT) AS $$
BEGIN
    RETURN QUERY
    SELECT i.instance_id
    FROM {schema}.instances i
    ORDER BY i.created_at DESC;
END;
$$ LANGUAGE plpgsql;
```

### Rust Code (After)
```rust
sqlx::query_scalar(&format!(
    "SELECT instance_id FROM {}.sp_list_instances()",
    self.schema_name
))
.fetch_all(&*self.pool)
```

## Critical Procedures

### Most Complex: `ack_orchestration_item`
- **Operations**: 10+ database operations in single transaction
- **Strategy**: Consider breaking into sub-procedures
- **Risk**: High - core functionality

### Most Critical: `fetch_orchestration_item`
- **Operations**: SELECT FOR UPDATE SKIP LOCKED, lock acquisition
- **Strategy**: Must maintain transaction isolation
- **Risk**: High - concurrency sensitive

## Testing Strategy

1. **Unit Tests**: Test each procedure independently
2. **Integration Tests**: Test Rust code calling procedures
3. **Concurrency Tests**: Especially for queue operations
4. **Performance Tests**: Compare before/after
5. **Regression Tests**: Full test suite

## Rollback Plan

1. **Feature Flag**: Switch between SQL and procedures
2. **Keep Old SQL**: As comments during migration
3. **Migration Rollback**: Drop procedures if needed

## Success Criteria

- ✅ All SQL queries converted to procedures
- ✅ All tests passing
- ✅ Performance maintained or improved
- ✅ No regression in functionality
- ✅ Documentation updated

## Documentation Files

1. **STORED_PROCEDURE_MIGRATION_PLAN.md** - Detailed plan and design
2. **STORED_PROCEDURE_ACTION_PLAN.md** - Actionable checklist and templates
3. **This file** - Executive summary and quick reference

## Next Steps

1. Review and approve migration plan
2. Set up migration infrastructure
3. Start with Priority 1 procedures (simple SELECTs)
4. Follow incremental approach
5. Test thoroughly at each phase

## Notes

- Consider using `RETURNS JSONB` for complex return types
- Use `SECURITY DEFINER` if access control needed
- Document all procedures with comments
- Monitor query performance after migration
- Keep error handling consistent

