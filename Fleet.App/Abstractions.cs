namespace Fleet.App;

public record Vehicle(long Id, string Vin, string PlateNumber, string Brand, string Model,
    string FuelType, string Status, decimal OdometerKm, int ManufactureYear, bool IsInsured,
    DateTime UpdatedAt, long? UpdatedBy);

public record Driver(long Id, string FullName, string Phone, string LicenseNumber,
    DateOnly LicenseExpiry, bool LicenseValid, string Categories, DateTime UpdatedAt, long? UpdatedBy);

public record Trip(long Id, long VehicleId, long DriverId, string PlateNumber, string DriverName,
    string Purpose, string StartLocation, string EndLocation, DateTime StartedAt,
    DateTime? FinishedAt, decimal? DistanceKm, string Status);

public record NewVehicle(int ModelId, int FuelTypeId, string Vin, string Plate, int Year,
    string? Color, decimal? TankL, decimal? OdometerKm);

public record NewDriver(string FirstName, string LastName, string? Phone, string LicenseNumber,
    DateOnly LicenseExpiry, DateOnly? HiredAt);

public interface IVehicleRepository
{
    Task<IReadOnlyList<Vehicle>> GetAllAsync();
    Task<Vehicle?> GetByIdAsync(long id);
    Task<long> CreateAsync(NewVehicle v, long userId);
    Task UpdateAsync(long id, string? plate, string? color, int? statusId, long userId);
    Task SoftDeleteAsync(long id, long userId);
    Task RestoreAsync(long id, long userId);
}

public interface IDriverRepository
{
    Task<IReadOnlyList<Driver>> GetAllAsync();
    Task<Driver?> GetByIdAsync(long id);
    Task<long> CreateAsync(NewDriver d, long userId);
    Task UpdateAsync(long id, string? phone, DateOnly? licenseExpiry, long userId);
    Task AddCategoryAsync(long id, string categoryCode, long userId);
    Task SoftDeleteAsync(long id, long userId);
    Task RestoreAsync(long id, long userId);
}

public interface ITripRepository
{
    Task<IReadOnlyList<Trip>> GetAllAsync();
    Task<IReadOnlyList<Trip>> GetActiveAsync();
    Task<Trip?> GetByIdAsync(long id);
    Task<long> StartAsync(long vehicleId, long driverId, string? purpose, string from, string to, long userId);
    Task FinishAsync(long tripId, decimal endOdometerKm, long userId);
    Task CancelAsync(long tripId, long userId);
}

public interface IUnitOfWork : IAsyncDisposable
{
    IVehicleRepository Vehicles { get; }
    IDriverRepository Drivers { get; }
    ITripRepository Trips { get; }

    Task BeginAsync();
    Task CommitAsync();
    Task RollbackAsync();
}
