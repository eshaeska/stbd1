using Npgsql;

namespace Fleet.App;

public sealed class UnitOfWork : IUnitOfWork
{
    private readonly NpgsqlConnection _conn;
    private NpgsqlTransaction? _tx;

    private IVehicleRepository? _vehicles;
    private IDriverRepository? _drivers;
    private ITripRepository? _trips;

    private UnitOfWork(NpgsqlConnection conn) => _conn = conn;

    public static async Task<UnitOfWork> OpenAsync(string connectionString)
    {
        var conn = new NpgsqlConnection(connectionString);
        await conn.OpenAsync();
        return new UnitOfWork(conn);
    }

    public IVehicleRepository Vehicles => _vehicles ??= new VehicleRepository(this);
    public IDriverRepository Drivers   => _drivers  ??= new DriverRepository(this);
    public ITripRepository Trips       => _trips    ??= new TripRepository(this);

    public async Task BeginAsync()
    {
        if (_tx is not null) throw new InvalidOperationException("Транзакція вже розпочата.");
        _tx = await _conn.BeginTransactionAsync();
    }

    public async Task CommitAsync()
    {
        if (_tx is null) throw new InvalidOperationException("Немає активної транзакції.");
        await _tx.CommitAsync();
        await _tx.DisposeAsync();
        _tx = null;
    }

    public async Task RollbackAsync()
    {
        if (_tx is null) return;
        await _tx.RollbackAsync();
        await _tx.DisposeAsync();
        _tx = null;
    }

    internal NpgsqlCommand CreateCommand(string sql, params (string Name, object? Value)[] parameters)
    {
        var cmd = new NpgsqlCommand(sql, _conn, _tx);
        foreach (var (name, value) in parameters)
            cmd.Parameters.Add(new NpgsqlParameter(name, value ?? DBNull.Value));
        return cmd;
    }

    public async ValueTask DisposeAsync()
    {
        if (_tx is not null)          
        {
            await _tx.RollbackAsync();
            await _tx.DisposeAsync();
        }
        await _conn.DisposeAsync();
    }
}
