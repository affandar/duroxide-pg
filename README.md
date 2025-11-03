# Duroxide PostgreSQL Provider

A PostgreSQL-based provider implementation for [Duroxide](https://github.com/affandar/duroxide), a durable task orchestration framework.

## Setup

1. **Install dependencies:**
   ```bash
   cargo build
   ```

2. **Configure database connection:**
   ```bash
   cp .env.example .env
   # Edit .env with your PostgreSQL connection string
   ```

3. **Environment Variables:**
   - `DATABASE_URL`: PostgreSQL connection string (e.g., `postgres://user:password@localhost:5432/database`)

## Implementation Status

This is a work-in-progress implementation. The provider scaffold is set up with:

- ✅ Basic project structure
- ✅ Duroxide dependency with `provider-test` feature enabled
- ✅ PostgreSQL connection setup
- ⏳ Schema initialization (TODO)
- ⏳ Provider trait implementation (TODO)
- ⏳ Tests (TODO)

## References

- [Provider Implementation Guide](https://github.com/affandar/duroxide/blob/main/docs/provider-implementation-guide.md)
- [Architecture Documentation](https://github.com/affandar/duroxide/blob/main/docs/architecture.md)
- [Reference Implementation](https://github.com/affandar/duroxide/tree/main/src/providers/sqlite.rs)

