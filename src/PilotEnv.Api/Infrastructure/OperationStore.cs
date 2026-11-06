using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Options;
using System.Text.Json;

namespace PilotEnv.Api;

public sealed class OperationStore
{
    private readonly string _connectionString;
    private readonly string _instancesRoot;

    public OperationStore(IOptions<PilotEnvOptions> options, IWebHostEnvironment environment)
    {
        var path = options.Value.ResolvePath(environment.ContentRootPath, options.Value.DatabaseFile);
        _instancesRoot = Path.Combine(options.Value.ResolveRepositoryRoot(environment.ContentRootPath), ".pilot-instances");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        _connectionString = new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadWriteCreate, Pooling = false, DefaultTimeout = 30 }.ToString();
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.CommandText = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS operations (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                environment_name TEXT NULL,
                component TEXT NULL,
                state TEXT NOT NULL,
                request_json TEXT NULL,
                result_json TEXT NULL,
                error TEXT NULL,
                idempotency_scope TEXT NULL,
                idempotency_key TEXT NULL,
                created_at TEXT NOT NULL,
                started_at TEXT NULL,
                finished_at TEXT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS ux_operations_idempotency
                ON operations(idempotency_scope, idempotency_key)
                WHERE idempotency_key IS NOT NULL;
            CREATE INDEX IF NOT EXISTS ix_operations_chronology ON operations(created_at DESC,id DESC);
            CREATE INDEX IF NOT EXISTS ix_operations_environment_history ON operations(environment_name,created_at DESC,id DESC);
            CREATE TABLE IF NOT EXISTS environment_metadata (
                name TEXT PRIMARY KEY,
                owner TEXT NOT NULL,
                description TEXT NULL
            );
            CREATE TABLE IF NOT EXISTS resource_reservations (
                operation_id TEXT PRIMARY KEY,
                environment_name TEXT NOT NULL,
                memory_gib REAL NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS public_port_assignments (
                environment_name TEXT PRIMARY KEY,
                operation_id TEXT NOT NULL,
                web_port INTEGER NOT NULL UNIQUE,
                admin_port INTEGER NOT NULL UNIQUE,
                committed INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS audit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                occurred_at TEXT NOT NULL,
                action TEXT NOT NULL,
                target TEXT NULL,
                outcome TEXT NOT NULL,
                details TEXT NULL
            );
            """;
        await command.ExecuteNonQueryAsync(cancellationToken);

        command.CommandText = """
            UPDATE operations
               SET state='failed', error='API service restarted while the operation was running.', finished_at=$now
             WHERE state='running';
            DELETE FROM resource_reservations
             WHERE operation_id IN (SELECT id FROM operations WHERE state IN ('failed','succeeded'));
            """;
        command.Parameters.AddWithValue("$now", DateTimeOffset.UtcNow.ToString("O"));
        await command.ExecuteNonQueryAsync(cancellationToken);

        command.Parameters.Clear();
        command.CommandText = "SELECT environment_name,committed,operation_id FROM public_port_assignments";
        var assignments = new List<(string Name, bool Committed, string OperationId)>();
        await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken)) assignments.Add((reader.GetString(0), reader.GetInt32(1) != 0, reader.GetString(2)));
        foreach (var assignment in assignments)
        {
            command.Parameters.Clear();
            var exists = File.Exists(Path.Combine(_instancesRoot, assignment.Name, "instance.json"));
            if (exists && assignment.Committed) continue;
            if (!exists && !assignment.Committed)
            {
                command.CommandText = "SELECT COUNT(*) FROM operations WHERE id=$id AND state='queued'";
                command.Parameters.AddWithValue("$id", assignment.OperationId);
                var queued = Convert.ToInt64(await command.ExecuteScalarAsync(cancellationToken)) > 0;
                command.Parameters.Clear();
                if (queued) continue;
            }
            command.CommandText = exists
                ? "UPDATE public_port_assignments SET committed=1 WHERE environment_name=$name"
                : "DELETE FROM public_port_assignments WHERE environment_name=$name";
            command.Parameters.AddWithValue("$name", assignment.Name);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }

        if (Directory.Exists(_instancesRoot))
        {
            foreach (var configPath in Directory.EnumerateFiles(_instancesRoot, "instance.json", SearchOption.AllDirectories))
            {
                using var config = JsonDocument.Parse(await File.ReadAllTextAsync(configPath, cancellationToken));
                if (!config.RootElement.TryGetProperty("publicPorts", out var ports) || ports.ValueKind != JsonValueKind.Object) continue;
                var name = config.RootElement.GetProperty("name").GetString();
                if (string.IsNullOrWhiteSpace(name)) continue;
                command.Parameters.Clear();
                command.CommandText = """
                    INSERT INTO public_port_assignments(environment_name,operation_id,web_port,admin_port,committed,created_at)
                    VALUES($name,$operation,$web,$admin,1,$created)
                    ON CONFLICT(environment_name) DO NOTHING;
                    """;
                command.Parameters.AddWithValue("$name", name);
                command.Parameters.AddWithValue("$operation", "recovered:" + name);
                command.Parameters.AddWithValue("$web", ports.GetProperty("web").GetInt32());
                command.Parameters.AddWithValue("$admin", ports.GetProperty("admin").GetInt32());
                command.Parameters.AddWithValue("$created", DateTimeOffset.UtcNow.ToString("O"));
                await command.ExecuteNonQueryAsync(cancellationToken);
            }
        }
    }

    public async Task<OperationRecord> CreateAsync(
        string kind,
        string? environmentName,
        string? component,
        string? requestJson,
        string? idempotencyKey,
        bool reserveMemory,
        double memoryGiB,
        PublicPortPair? publicPorts,
        CancellationToken cancellationToken)
    {
        var scope = $"{kind}:{environmentName}:{component}";
        await using var connection = await OpenAsync(cancellationToken);
        await using var transaction = (SqliteTransaction)await connection.BeginTransactionAsync(cancellationToken);

        if (!string.IsNullOrWhiteSpace(idempotencyKey))
        {
            var existing = await FindByIdempotencyAsync(connection, transaction, scope, idempotencyKey, cancellationToken);
            if (existing is not null)
            {
                if (!string.Equals(existing.RequestJson, requestJson, StringComparison.Ordinal))
                    throw new ApiProblemException("idempotency_conflict", "Idempotency-Key was already used with a different request.", 409);
                await transaction.CommitAsync(cancellationToken);
                return existing;
            }
        }

        var record = new OperationRecord
        {
            Id = Guid.NewGuid(), Kind = kind, EnvironmentName = environmentName, Component = component,
            RequestJson = requestJson, CreatedAt = DateTimeOffset.UtcNow
        };
        var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO operations(id,kind,environment_name,component,state,request_json,idempotency_scope,idempotency_key,created_at)
            VALUES($id,$kind,$environment,$component,'queued',$request,$scope,$key,$created);
            """;
        command.Parameters.AddWithValue("$id", record.Id.ToString());
        command.Parameters.AddWithValue("$kind", kind);
        command.Parameters.AddWithValue("$environment", (object?)environmentName ?? DBNull.Value);
        command.Parameters.AddWithValue("$component", (object?)component ?? DBNull.Value);
        command.Parameters.AddWithValue("$request", (object?)requestJson ?? DBNull.Value);
        command.Parameters.AddWithValue("$scope", string.IsNullOrWhiteSpace(idempotencyKey) ? DBNull.Value : scope);
        command.Parameters.AddWithValue("$key", string.IsNullOrWhiteSpace(idempotencyKey) ? DBNull.Value : idempotencyKey);
        command.Parameters.AddWithValue("$created", record.CreatedAt.ToString("O"));
        await command.ExecuteNonQueryAsync(cancellationToken);

        if (reserveMemory && environmentName is not null)
        {
            command.Parameters.Clear();
            command.CommandText = """
                INSERT INTO resource_reservations(operation_id,environment_name,memory_gib,created_at)
                VALUES($id,$environment,$memory,$created);
                """;
            command.Parameters.AddWithValue("$id", record.Id.ToString());
            command.Parameters.AddWithValue("$environment", environmentName);
            command.Parameters.AddWithValue("$memory", memoryGiB);
            command.Parameters.AddWithValue("$created", record.CreatedAt.ToString("O"));
            await command.ExecuteNonQueryAsync(cancellationToken);
        }

        if (publicPorts is not null && environmentName is not null)
        {
            command.Parameters.Clear();
            command.CommandText = """
                INSERT INTO public_port_assignments(environment_name,operation_id,web_port,admin_port,committed,created_at)
                VALUES($environment,$id,$web,$admin,0,$created);
                """;
            command.Parameters.AddWithValue("$environment", environmentName);
            command.Parameters.AddWithValue("$id", record.Id.ToString());
            command.Parameters.AddWithValue("$web", publicPorts.Web);
            command.Parameters.AddWithValue("$admin", publicPorts.Admin);
            command.Parameters.AddWithValue("$created", record.CreatedAt.ToString("O"));
            try { await command.ExecuteNonQueryAsync(cancellationToken); }
            catch (SqliteException ex) when (ex.SqliteErrorCode == 19)
            {
                throw new ApiProblemException("public_ports_unavailable", "The selected public port pair was reserved concurrently.", 409);
            }
        }

        await transaction.CommitAsync(cancellationToken);
        return record;
    }

    public async Task SetMetadataAsync(EnvironmentMetadata metadata, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.CommandText = """
            INSERT INTO environment_metadata(name,owner,description) VALUES($name,$owner,$description)
            ON CONFLICT(name) DO UPDATE SET owner=excluded.owner, description=excluded.description;
            """;
        command.Parameters.AddWithValue("$name", metadata.Name);
        command.Parameters.AddWithValue("$owner", metadata.Owner);
        command.Parameters.AddWithValue("$description", (object?)metadata.Description ?? DBNull.Value);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<Dictionary<string, EnvironmentMetadata>> GetMetadataAsync(CancellationToken cancellationToken)
    {
        var result = new Dictionary<string, EnvironmentMetadata>(StringComparer.OrdinalIgnoreCase);
        await using var connection = await OpenAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.CommandText = "SELECT name,owner,description FROM environment_metadata";
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            var item = new EnvironmentMetadata { Name = reader.GetString(0), Owner = reader.GetString(1), Description = reader.IsDBNull(2) ? null : reader.GetString(2) };
            result[item.Name] = item;
        }
        return result;
    }

    public async Task<IReadOnlySet<string>> GetReservedEnvironmentNamesAsync(CancellationToken cancellationToken)
    {
        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        await using var connection = await OpenAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.CommandText = "SELECT DISTINCT environment_name FROM resource_reservations";
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) result.Add(reader.GetString(0));
        return result;
    }

    public async Task<IReadOnlyDictionary<string, PublicPortPair>> GetPublicPortAssignmentsAsync(CancellationToken cancellationToken)
    {
        var result = new Dictionary<string, PublicPortPair>(StringComparer.OrdinalIgnoreCase);
        await using var connection = await OpenAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.CommandText = "SELECT environment_name,web_port,admin_port FROM public_port_assignments";
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) result[reader.GetString(0)] = new PublicPortPair(reader.GetInt32(1), reader.GetInt32(2));
        return result;
    }

    public async Task<PublicPortPair?> GetPublicPortsForEnvironmentAsync(string name, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.CommandText = "SELECT web_port,admin_port FROM public_port_assignments WHERE environment_name=$name";
        command.Parameters.AddWithValue("$name", name);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken) ? new PublicPortPair(reader.GetInt32(0), reader.GetInt32(1)) : null;
    }

    public async Task CommitPublicPortsAsync(Guid operationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.CommandText = "UPDATE public_port_assignments SET committed=1 WHERE operation_id=$id";
        command.Parameters.AddWithValue("$id", operationId.ToString());
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task ReleasePublicPortsAsync(string environmentName, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM public_port_assignments WHERE environment_name=$name";
        command.Parameters.AddWithValue("$name", environmentName);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<IReadOnlyList<Guid>> GetQueuedIdsAsync(CancellationToken cancellationToken)
    {
        var result = new List<Guid>();
        await using var connection = await OpenAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.CommandText = "SELECT id FROM operations WHERE state='queued' ORDER BY created_at";
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) result.Add(Guid.Parse(reader.GetString(0)));
        return result;
    }

    private sealed record HistoryCursor(string CreatedAt, string Id, string? EnvironmentName, string? Kind, string? State);
    public async Task<OperationPage> ListAsync(string? environmentName, string? kind, string? state,
        int limit = 25, string? cursor = null, CancellationToken cancellationToken = default)
    {
        if (limit is < 1 or > 100 || (environmentName is not null &&
            environmentName != "$release-validation" && !System.Text.RegularExpressions.Regex.IsMatch(environmentName, "^[a-z0-9][a-z0-9-]{0,39}$")) ||
            (kind is not null && kind is not ("create" or "start" or "stop" or "restart" or "recreate" or "delete" or "refresh-release")) ||
            (state is not null && state is not ("active" or "queued" or "running" or "succeeded" or "failed")))
            throw new ApiProblemException("invalid_filter", "Invalid operation history filter.");
        HistoryCursor? after = null;
        if (cursor is not null)
        {
            try
            {
                if (cursor.Length > 2048) throw new FormatException();
                after = JsonSerializer.Deserialize<HistoryCursor>(Microsoft.AspNetCore.WebUtilities.WebEncoders.Base64UrlDecode(cursor));
                if (after is null || !DateTimeOffset.TryParse(after.CreatedAt, out _) || !Guid.TryParseExact(after.Id,"D",out _) ||
                    after.EnvironmentName != environmentName || after.Kind != kind || after.State != state) throw new FormatException();
            }
            catch { throw new ApiProblemException("invalid_cursor", "Invalid operation history cursor."); }
        }
        await using var connection = await OpenAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.CommandText = """
            SELECT id,kind,environment_name,component,state,created_at,started_at,finished_at
              FROM operations
             WHERE ($environment IS NULL OR environment_name=$environment)
               AND ($kind IS NULL OR kind=$kind)
               AND ($state IS NULL OR state=$state OR ($state='active' AND state IN ('queued','running')))
               AND ($created IS NULL OR created_at<$created OR (created_at=$created AND id<$id))
             ORDER BY created_at DESC,id DESC LIMIT $limit
            """;
        command.Parameters.AddWithValue("$environment", (object?)environmentName ?? DBNull.Value);
        command.Parameters.AddWithValue("$kind", (object?)kind ?? DBNull.Value);
        command.Parameters.AddWithValue("$state", (object?)state ?? DBNull.Value);
        command.Parameters.AddWithValue("$created", (object?)after?.CreatedAt ?? DBNull.Value);
        command.Parameters.AddWithValue("$id", (object?)after?.Id ?? DBNull.Value);
        command.Parameters.AddWithValue("$limit", limit + 1);
        var rows = new List<(OperationSummary Summary, string Created)>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) rows.Add((ReadSummary(reader),reader.GetString(5)));
        string? next = null;
        if (rows.Count > limit)
        {
            rows.RemoveAt(rows.Count-1);
            var last=rows[^1];
            next=Microsoft.AspNetCore.WebUtilities.WebEncoders.Base64UrlEncode(JsonSerializer.SerializeToUtf8Bytes(
                new HistoryCursor(last.Created,last.Summary.Id.ToString(),environmentName,kind,state)));
        }
        return new OperationPage(rows.Select(x=>x.Summary).ToArray(),next);
    }

    public async Task<IReadOnlyDictionary<string, OperationSummary>> GetLatestByEnvironmentAsync(CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        var command = connection.CreateCommand();
        command.CommandText = """
            SELECT id,kind,environment_name,component,state,created_at,started_at,finished_at FROM
            (SELECT id,kind,environment_name,component,state,created_at,started_at,finished_at,
                ROW_NUMBER() OVER(PARTITION BY environment_name ORDER BY created_at DESC,id DESC) AS row_number
                FROM operations WHERE environment_name IS NOT NULL) WHERE row_number=1
            """;
        var result=new Dictionary<string,OperationSummary>(StringComparer.OrdinalIgnoreCase);
        await using var reader=await command.ExecuteReaderAsync(ct);
        while(await reader.ReadAsync(ct)){var item=ReadSummary(reader);result[item.EnvironmentName!]=item;}
        return result;
    }
    private static OperationSummary ReadSummary(SqliteDataReader reader) => new(
        Guid.Parse(reader.GetString(0)),reader.GetString(1),reader.IsDBNull(2)?null:reader.GetString(2),
        reader.IsDBNull(3)?null:reader.GetString(3),reader.GetString(4),DateTimeOffset.Parse(reader.GetString(5)),
        reader.IsDBNull(6)?null:DateTimeOffset.Parse(reader.GetString(6)),reader.IsDBNull(7)?null:DateTimeOffset.Parse(reader.GetString(7)));

    public async Task<OperationRecord?> GetAsync(Guid id, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.CommandText = "SELECT id,kind,environment_name,component,state,request_json,result_json,error,created_at,started_at,finished_at FROM operations WHERE id=$id";
        command.Parameters.AddWithValue("$id", id.ToString());
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken) ? ReadOperation(reader) : null;
    }

    public async Task<OperationRecord?> GetByIdempotencyAsync(string kind, string? environmentName, string? component,
        string? key, string? requestJson, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(key)) return null;
        var scope = $"{kind}:{environmentName}:{component}";
        await using var connection = await OpenAsync(cancellationToken);
        await using var transaction = (SqliteTransaction)await connection.BeginTransactionAsync(cancellationToken);
        var existing = await FindByIdempotencyAsync(connection, transaction, scope, key, cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        if (existing is not null && !string.Equals(existing.RequestJson, requestJson, StringComparison.Ordinal))
            throw new ApiProblemException("idempotency_conflict", "Idempotency-Key was already used with a different request.", 409);
        return existing;
    }

    public async Task<OperationRecord?> GetActiveForEnvironmentAsync(string name, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.CommandText = """
            SELECT id,kind,environment_name,component,state,request_json,result_json,error,created_at,started_at,finished_at
              FROM operations WHERE environment_name=$name AND state IN ('queued','running') ORDER BY created_at LIMIT 1
            """;
        command.Parameters.AddWithValue("$name", name);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken) ? ReadOperation(reader) : null;
    }

    public async Task<IReadOnlyList<OperationRecord>> GetActiveAsync(CancellationToken cancellationToken)
    {
        var result = new List<OperationRecord>();
        await using var connection = await OpenAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.CommandText = """
            SELECT id,kind,environment_name,component,state,request_json,result_json,error,created_at,started_at,finished_at
              FROM operations WHERE state IN ('queued','running') ORDER BY created_at
            """;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) result.Add(ReadOperation(reader));
        return result;
    }

    public async Task MarkRunningAsync(Guid id, CancellationToken cancellationToken) =>
        await UpdateStateAsync(id, "running", null, null, true, false, cancellationToken);

    public async Task CompleteAsync(Guid id, string resultJson, CancellationToken cancellationToken) =>
        await UpdateStateAsync(id, "succeeded", resultJson, null, false, true, cancellationToken);

    public async Task FailAsync(Guid id, string error, CancellationToken cancellationToken) =>
        await UpdateStateAsync(id, "failed", null, error, false, true, cancellationToken);

    public async Task RemoveMetadataAsync(string name, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM environment_metadata WHERE name=$name";
        command.Parameters.AddWithValue("$name", name);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private async Task UpdateStateAsync(Guid id, string state, string? result, string? error, bool started, bool finished, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var transaction = (SqliteTransaction)await connection.BeginTransactionAsync(cancellationToken);
        var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            UPDATE operations SET state=$state, result_json=$result, error=$error,
                started_at=CASE WHEN $started=1 THEN $now ELSE started_at END,
                finished_at=CASE WHEN $finished=1 THEN $now ELSE finished_at END
             WHERE id=$id;
            """;
        command.Parameters.AddWithValue("$state", state);
        command.Parameters.AddWithValue("$result", (object?)result ?? DBNull.Value);
        command.Parameters.AddWithValue("$error", (object?)error ?? DBNull.Value);
        command.Parameters.AddWithValue("$started", started ? 1 : 0);
        command.Parameters.AddWithValue("$finished", finished ? 1 : 0);
        command.Parameters.AddWithValue("$now", DateTimeOffset.UtcNow.ToString("O"));
        command.Parameters.AddWithValue("$id", id.ToString());
        await command.ExecuteNonQueryAsync(cancellationToken);
        if (finished)
        {
            command.Parameters.Clear();
            command.CommandText = "DELETE FROM resource_reservations WHERE operation_id=$id";
            command.Parameters.AddWithValue("$id", id.ToString());
            await command.ExecuteNonQueryAsync(cancellationToken);
            if (state == "failed")
            {
                command.Parameters.Clear();
                command.CommandText = "DELETE FROM public_port_assignments WHERE operation_id=$id AND committed=0";
                command.Parameters.AddWithValue("$id", id.ToString());
                await command.ExecuteNonQueryAsync(cancellationToken);
            }
        }
        await transaction.CommitAsync(cancellationToken);
    }

    private static async Task<OperationRecord?> FindByIdempotencyAsync(SqliteConnection connection, SqliteTransaction transaction, string scope, string key, CancellationToken cancellationToken)
    {
        var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT id,kind,environment_name,component,state,request_json,result_json,error,created_at,started_at,finished_at FROM operations WHERE idempotency_scope=$scope AND idempotency_key=$key";
        command.Parameters.AddWithValue("$scope", scope);
        command.Parameters.AddWithValue("$key", key);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken) ? ReadOperation(reader) : null;
    }

    private static OperationRecord ReadOperation(SqliteDataReader reader) => new()
    {
        Id = Guid.Parse(reader.GetString(0)), Kind = reader.GetString(1),
        EnvironmentName = reader.IsDBNull(2) ? null : reader.GetString(2),
        Component = reader.IsDBNull(3) ? null : reader.GetString(3), State = reader.GetString(4),
        RequestJson = reader.IsDBNull(5) ? null : reader.GetString(5), ResultJson = reader.IsDBNull(6) ? null : reader.GetString(6),
        Error = reader.IsDBNull(7) ? null : reader.GetString(7), CreatedAt = DateTimeOffset.Parse(reader.GetString(8)),
        StartedAt = reader.IsDBNull(9) ? null : DateTimeOffset.Parse(reader.GetString(9)),
        FinishedAt = reader.IsDBNull(10) ? null : DateTimeOffset.Parse(reader.GetString(10))
    };

    private async Task<SqliteConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connection = new SqliteConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);
        return connection;
    }
}
