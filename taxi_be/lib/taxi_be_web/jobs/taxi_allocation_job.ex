defmodule TaxiBeWeb.TaxiAllocationJob do
  use GenServer

  def start_link(request, name) do
    GenServer.start_link(__MODULE__, request, name: name)
  end

  def init(request) do
    Process.send(self(), :step1, [:nosuspend])
    {:ok, %{request: request, status: NotAccepted}}
  end

  def handle_info(:step1, %{request: request, status: NotAccepted} = state) do

    # send customer ride fare
    task = Task.async(fn ->
      compute_ride_fare(request)
      |> notify_customer_ride_fare()
    end)
    Task.await(task)

    # get all taxis
    taxis = select_candidate_taxis(request)

    %{"booking_id" => booking_id} = request

    # send out requests to all taxis
    Enum.map(taxis, fn taxi -> TaxiBeWeb.Endpoint.broadcast("driver:" <> taxi.nickname, "booking_request", %{msg: "viaje disponible", bookingId: booking_id}) end)

    # repeat immediate process

    Process.send_after(self(), :timelimit, 20000)
    {:noreply, state |> Map.put(:time, Good)}
  end

  def handle_info(:timelimit, %{request: request, status: NotAccepted} = state) do
    # IO.inspect(state)
    %{"username" => customer} = request
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "A problem looking for a driver has arisen"})
    {:noreply, %{state | time: Exceeded}}
  end

  def handle_info(:timelimit, %{status: Accepted} = state) do

    {:noreply, %{state | time: Exceeded}}
  end

  def handle_cast({:process_accept, driver_username}, %{request: request, status: NotAccepted, time: Good} = state) do
    %{"username" => customer,
    "pickup_address" => pickup} = request

    taxi = select_candidate_taxis(request)
    |> Enum.find(fn item -> item.nickname == driver_username end)


    arrival = compute_estimated_arrival(pickup, taxi)

    IO.inspect(arrival)

    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "Driver #{driver_username} on the way, in #{round(Float.floor(arrival/60, 0))} minutes and #{rem(round(arrival), 60)} seconds"})
    {:noreply, %{state | status: Accepted}}
  end

  def handle_cast({:process_accept, driver_username}, %{status: Accepted} = state) do
    TaxiBeWeb.Endpoint.broadcast("driver:" <> driver_username, "booking_notification", %{msg: "Ha sido aceptado por otro conductor"})
    {:noreply, state}
  end

  def handle_cast({:process_accept, driver_username}, %{status: NotAccepted, time: Exceeded} = state) do
    TaxiBeWeb.Endpoint.broadcast("driver:" <> driver_username, "booking_notification", %{msg: "Aceptacion demasiada tarde"})
    {:noreply, state}
  end

  def handle_cast({:process_reject, driver_username}, state) do
    {:noreply, state}
  end

  def compute_ride_fare(request) do
    %{
      "pickup_address" => pickup_address,
      "dropoff_address" => dropoff_address
     } = request

    coord1 = TaxiBeWeb.Geolocator.geocode(pickup_address)
    coord2 = TaxiBeWeb.Geolocator.geocode(dropoff_address)
    {distance, _duration} = TaxiBeWeb.Geolocator.distance_and_duration(coord1, coord2)
    {request, Float.ceil(distance/300)}
  end

  def compute_estimated_arrival(pickup_address, taxi) do
    coord1 = {:ok, [taxi.longitude, taxi.latitude]}
    coord2 = TaxiBeWeb.Geolocator.geocode(pickup_address)
    {_distance, duration} = TaxiBeWeb.Geolocator.distance_and_duration(coord1, coord2)
    duration
  end

  def notify_customer_ride_fare({request, fare}) do
    %{"username" => customer} = request
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "Ride fare: #{fare}"})
  end

  def select_candidate_taxis(%{"pickup_address" => _pickup_address}) do
    [
      %{nickname: "frodo", latitude: 19.0319783, longitude: -98.2349368}, # Angelopolis
      %{nickname: "samwise", latitude: 19.0061167, longitude: -98.2697737}, # Arcangeles
      %{nickname: "merry", latitude: 19.0092933, longitude: -98.2473716} # Paseo Destino
    ]
  end
end
