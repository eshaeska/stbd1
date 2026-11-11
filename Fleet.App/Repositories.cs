using Npgsql;

namespace Fleet.App;

internal static class ReaderExt
{
    public static T Get<T>(this NpgsqlDataReader r, string col) => r.GetFieldValue<T>(r.GetOrdinal(col));

    public static T? GetN<T>(this NpgsqlDataReader r, string col) where T : struct
    {
        var i = r.GetOrdinal(col);
        return r.IsDBNull(i) ? null : r.GetFieldValue<T>(i);
    }
}

internal abstract class RepositoryBase
{
    protected readonly UnitOfWork Uow;
    protected RepositoryBase(UnitOfWork uow) => Uow = uow;

    protected async Task<List<T>> QueryAsync<T>(string sql, Func<NpgsqlDataReader, T> map,
        params (string, object?)[] p)
    {
        await using var cmd = Uow.CreateCommand(sql, p);
        await using var r = await cmd.ExecuteReaderAsync();
        var list = new List<T>();
        while (await r.ReadAsync()) list.Add(map(r));
        return list;
    }

    protected async Task<T?> QuerySingleAsync<T>(string sql, Func<NpgsqlDataReader, T> map,
        params (string, object?)[] p) where T : class
        => (await QueryAsync(sql, map, p)).FirstOrDefault();

    protected async Task<long> ScalarIdAsync(string sql, params (string, object?)[] p)
    {
        await using var cmd = Uow.CreateCommand(sql, p);
        return (long)(await cmd.ExecuteScalarAsync())!;
    }

    protected async Task ExecAsync(string sql, params (string, object?)[] p)
    {
        await using var cmd = Uow.CreateCommand(sql, p);
        await cmd.ExecuteNonQueryAsync();
    }
}

internal sealed class VehicleRepository : RepositoryBase, IVehicleRepository
{
    public VehicleRepository(UnitOfWork uow) : base(uow) { }

    private static Vehicle Map(NpgsqlDataReader r) => new(
        r.Get<long>("vehicle_id"), r.Get<string>("vin"), r.Get<string>("plate_number"),
        r.Get<string>("brand"), r.Get<string>("model"), r.Get<string>("fuel_type"),
        r.Get<string>("status"), r.Get<decimal>("odometer_km"), r.Get<int>("manufacture_year"),
        r.Get<bool>("is_insured"), r.Get<DateTime>("updated_at"), r.GetN<long>("updated_by"));

    public async Task<IReadOnlyList<Vehicle>> GetAllAsync()
        => await QueryAsync("SELECT * FROM vw_active_vehicles ORDER BY vehicle_id", Map);

    public Task<Vehicle?> GetByIdAsync(long id)
        => QuerySingleAsync("SELECT * FROM vw_active_vehicles WHERE vehicle_id = @id", Map, ("id", id));

    public Task<long> CreateAsync(NewVehicle v, long userId)
        => ScalarIdAsync(
            "SELECT sp_vehicle_create(@model, @fuel, @vin, @plate, @year, @color::varchar, @tank::numeric, @odo::numeric, @user)",
            ("model", v.ModelId), ("fuel", v.FuelTypeId), ("vin", v.Vin), ("plate", v.Plate),
            ("year", v.Year), ("color", v.Color), ("tank", v.TankL), ("odo", v.OdometerKm), ("user", userId));

    public Task UpdateAsync(long id, string? plate, string? color, int? statusId, long userId)
        => ExecAsync("CALL sp_vehicle_update(@id, @plate::varchar, @color::varchar, @status::int, @user)",
            ("id", id), ("plate", plate), ("color", color), ("status", statusId), ("user", userId));

    public Task SoftDeleteAsync(long id, long userId)
        => ExecAsync("CALL sp_vehicle_soft_delete(@id, @user)", ("id", id), ("user", userId));

    public Task RestoreAsync(long id, long userId)
        => ExecAsync("CALL sp_vehicle_restore(@id, @user)", ("id", id), ("user", userId));
}

internal sealed class DriverRepository : RepositoryBase, IDriverRepository
{
    public DriverRepository(UnitOfWork uow) : base(uow) { }

    private static Driver Map(NpgsqlDataReader r) => new(
        r.Get<long>("driver_id"), r.Get<string>("full_name"), r.Get<string>("phone"),
        r.Get<string>("license_number"), r.Get<DateOnly>("license_expiry"),
        r.Get<bool>("license_valid"), r.Get<string>("categories"),
        r.Get<DateTime>("updated_at"), r.GetN<long>("updated_by"));

    public async Task<IReadOnlyList<Driver>> GetAllAsync()
        => await QueryAsync("SELECT * FROM vw_active_drivers ORDER BY driver_id", Map);

    public Task<Driver?> GetByIdAsync(long id)
        => QuerySingleAsync("SELECT * FROM vw_active_drivers WHERE driver_id = @id", Map, ("id", id));

    public Task<long> CreateAsync(NewDriver d, long userId)
        => ScalarIdAsync(
            "SELECT sp_driver_create(@first, @last, @phone::varchar, @lic, @exp, @hired::date, @user)",
            ("first", d.FirstName), ("last", d.LastName), ("phone", d.Phone), ("lic", d.LicenseNumber),
            ("exp", d.LicenseExpiry), ("hired", d.HiredAt), ("user", userId));

    public Task UpdateAsync(long id, string? phone, DateOnly? licenseExpiry, long userId)
        => ExecAsync("CALL sp_driver_update(@id, @phone::varchar, @exp::date, @user)",
            ("id", id), ("phone", phone), ("exp", licenseExpiry), ("user", userId));

    public Task AddCategoryAsync(long id, string categoryCode, long userId)
        => ExecAsync("CALL sp_driver_add_category(@id, @code, @user)",
            ("id", id), ("code", categoryCode), ("user", userId));

    public Task SoftDeleteAsync(long id, long userId)
        => ExecAsync("CALL sp_driver_soft_delete(@id, @user)", ("id", id), ("user", userId));

    public Task RestoreAsync(long id, long userId)
        => ExecAsync("CALL sp_driver_restore(@id, @user)", ("id", id), ("user", userId));
}

internal sealed class TripRepository : RepositoryBase, ITripRepository
{
    public TripRepository(UnitOfWork uow) : base(uow) { }

    private static Trip Map(NpgsqlDataReader r) => new(
        r.Get<long>("trip_id"), r.Get<long>("vehicle_id"), r.Get<long>("driver_id"),
        r.Get<string>("plate_number"), r.Get<string>("driver_name"), r.Get<string>("purpose"),
        r.Get<string>("start_location"), r.Get<string>("end_location"),
        r.Get<DateTime>("started_at"), r.GetN<DateTime>("finished_at"),
        r.GetN<decimal>("distance_km"), r.Get<string>("status"));

    public async Task<IReadOnlyList<Trip>> GetAllAsync()
        => await QueryAsync("SELECT * FROM vw_trip_details ORDER BY started_at DESC", Map);

    public async Task<IReadOnlyList<Trip>> GetActiveAsync()
        => await QueryAsync("SELECT * FROM vw_trip_details WHERE status = 'IN_PROGRESS' ORDER BY started_at", Map);

    public Task<Trip?> GetByIdAsync(long id)
        => QuerySingleAsync("SELECT * FROM vw_trip_details WHERE trip_id = @id", Map, ("id", id));

    public Task<long> StartAsync(long vehicleId, long driverId, string? purpose, string from, string to, long userId)
        => ScalarIdAsync("SELECT sp_trip_start(@veh, @drv, @purpose::varchar, @from, @to, @user)",
            ("veh", vehicleId), ("drv", driverId), ("purpose", purpose), ("from", from), ("to", to), ("user", userId));

    public Task FinishAsync(long tripId, decimal endOdometerKm, long userId)
        => ExecAsync("CALL sp_trip_finish(@id, @odo, @user)", ("id", tripId), ("odo", endOdometerKm), ("user", userId));

    public Task CancelAsync(long tripId, long userId)
        => ExecAsync("CALL sp_trip_cancel(@id, @user)", ("id", tripId), ("user", userId));
}
