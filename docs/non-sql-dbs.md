# ELK Monitor

## Elasticsearch and SQL Database Correspondence

| Elasticsearch | SQL Database |
|---|---|
| **Cluster** | Database Server / DBMS Instance |
| **Index** | Table |
| **Document** | Row / Record |
| **Field** | Column |
| **Mapping** | Schema |
| **Shard** | Partition |
| **Replica** | Backup / Replication Copy |
| **Type** (deprecated) | Schema / Database |
| **Analyzer** | Collation / Data Type Function |
| **Query DSL** | SQL Query |
| **Aggregation** | GROUP BY / Aggregate Functions |
| **Index Settings** | Table Properties (constraints, indexes) |

### Key Differences

- **Schema Flexibility**: Elasticsearch is schema-flexible (documents can have different fields), while SQL has rigid schemas
- **Full-Text Search**: Elasticsearch has native full-text search capabilities that SQL doesn't natively have
- **Sharding**: Elasticsearch handles automatic horizontal partitioning; SQL requires explicit partitioning
- **Replication**: Elasticsearch has built-in replication; SQL replication depends on the database system
