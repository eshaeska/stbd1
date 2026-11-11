using Fleet.App;

Console.OutputEncoding = System.Text.Encoding.UTF8;
const string cs = "Host=localhost;Port=5432;Database=fleets;Username=postgres;Password=";
const long adminId = 1; 

await using (var uow = await UnitOfWork.OpenAsync(cs))
{
    await uow.BeginAsync();
    try
    {
        var driverId = await uow.Drivers.CreateAsync(
            new NewDriver("Іван", "Петренко", "+380501112233", "AAA" + Random.Shared.Next(100000, 999999),
                DateOnly.FromDateTime(DateTime.Today.AddYears(3)), null), adminId);
        await uow.Drivers.AddCategoryAsync(driverId, "B", adminId);

        var vehicleId = await uow.Vehicles.CreateAsync(
            new NewVehicle(1, 1, "VIN" + Random.Shared.NextInt64(10000000000000, 99999999999999),
                "AA" + Random.Shared.Next(1000, 9999) + "KB", 2022, "Чорний", 60m, 1000m), adminId);

        var tripId = await uow.Trips.StartAsync(vehicleId, driverId, "Доставка", "Київ", "Львів", adminId);
        await uow.Trips.FinishAsync(tripId, 1540m, adminId);   

        await uow.CommitAsync();
        Console.WriteLine($"OK: водій {driverId}, авто {vehicleId}, рейс {tripId}");
    }
    catch (Exception ex)
    {
        await uow.RollbackAsync();
        Console.WriteLine("Відкат: " + ex.Message);
    }
}

await using (var uow = await UnitOfWork.OpenAsync(cs))
{
    await uow.BeginAsync();
    try
    {
        await uow.Drivers.CreateAsync(new NewDriver("Тест", "Відкат", null, "ZZZ000001",
            DateOnly.FromDateTime(DateTime.Today.AddYears(1)), null), adminId);
        await uow.Trips.StartAsync(999999, 999999, null, "A", "B", adminId); 
        await uow.CommitAsync();
    }
    catch (Exception ex)
    {
        await uow.RollbackAsync();
        Console.WriteLine("Очікуваний відкат: " + ex.Message);
    }
}

await using (var uow = await UnitOfWork.OpenAsync(cs))
{
    foreach (var v in await uow.Vehicles.GetAllAsync())
        Console.WriteLine($"{v.PlateNumber} {v.Brand} {v.Model} | {v.Status} | {v.OdometerKm} км | застрах.: {v.IsInsured}");
    foreach (var t in await uow.Trips.GetAllAsync())
        Console.WriteLine($"рейс {t.Id}: {t.PlateNumber} {t.DriverName} {t.StartLocation}->{t.EndLocation} {t.DistanceKm} км [{t.Status}]");

    var first = (await uow.Vehicles.GetAllAsync()).FirstOrDefault();
    if (first is not null)
    {
        await uow.Vehicles.SoftDeleteAsync(first.Id, adminId);
        Console.WriteLine("Після soft delete: " + (await uow.Vehicles.GetByIdAsync(first.Id) is null ? "не видно у VIEW" : "видно"));
        await uow.Vehicles.RestoreAsync(first.Id, adminId);
    }
}
