defmodule TaxiBeWeb.TaxiAllocationJob do
  use GenServer
  # se envia una peticion hacia los tres conductores
  # despues de 20 segundos sin aceptar la peticion se omite cualquier aceptacion de un conductor

  # en caso de aceptar se envia al cliente un mensaje de aprobacion y el tiempo que tarda en llegar
  # el conductor

  # en caso de ya ser aceptada por un conductor, otros conductores no podran aceptar

  def start_link(request, name) do
    GenServer.start_link(__MODULE__, request, name: name)
  end

  # inicializar estado con status: NotAccepted y madar a llamar step1
  def init(request) do
    Process.send(self(), :step1, [:nosuspend])
    {:ok, %{request: request, status: NotAccepted}}
  end

  # notificar los tres taxistas
  def handle_info(:step1, %{request: request, status: NotAccepted} = state) do

    # enviar costo a cliente
    task = Task.async(fn ->
      compute_ride_fare(request)
      |> notify_customer_ride_fare()
    end)
    Task.await(task)

    # obtener todos los taxists
    taxis = select_candidate_taxis(request)
    %{"booking_id" => booking_id} = request

    # mandar peticion a cada taxista
    Enum.map(taxis, fn taxi -> TaxiBeWeb.Endpoint.broadcast("driver:" <> taxi.nickname, "booking_request", %{msg: "viaje disponible", bookingId: booking_id}) end)

    # En 20 segundos cambiar estado para omitir cualquier aceptacion
    Process.send_after(self(), :timelimit, 20000)

    # agregar time: Good a estado para aceptar requests de taxistas
    {:noreply, state |> Map.put(:time, Good)}
  end

  # funcion de cancelacion por demora
  def handle_info(:timelimit, %{request: request, status: NotAccepted} = state) do
    # mandar mensaje de problema a conductor
    %{"username" => customer} = request
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "A problem looking for a driver has arisen"})

    # cambiar estad a time: Exceeded
    {:noreply, %{state | time: Exceeded}}
  end

  def handle_info(:timelimit, %{status: Accepted} = state) do
    # En caso de que ya es aceptada la peticion, solo modificar estado
    {:noreply, %{state | time: Exceeded}}
  end

  #  funcion de aceptacion cuando no ha sido aceptada y el tiempo es bueno
  def handle_cast({:process_accept, driver_username}, %{request: request, status: NotAccepted, time: Good} = state) do
    # obtener informacion para mensaje a cliente
    %{"username" => customer,
    "pickup_address" => pickup} = request
    taxi = select_candidate_taxis(request)
    |> Enum.find(fn item -> item.nickname == driver_username end)
    arrival = compute_estimated_arrival(pickup, taxi)

    # notificar a cliente el conductor y tiempo de llegada
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "Driver #{driver_username} on the way, in #{round(Float.floor(arrival/60, 0))} minutes and #{rem(round(arrival), 60)} seconds"})

    # cambiar estado a status: Accepted
    {:noreply, %{state | status: Accepted}}
  end

  # aceptacion en caso de que algun socio ya haya aceptado
  def handle_cast({:process_accept, driver_username}, %{status: Accepted} = state) do
    # enviar mensaje de que otro socio acepto y no modificar estado
    TaxiBeWeb.Endpoint.broadcast("driver:" <> driver_username, "booking_notification", %{msg: "Ha sido aceptado por otro conductor"})
    {:noreply, state}
  end

  # aceptacion en caso de tiempo excedido
  def handle_cast({:process_accept, driver_username}, %{status: NotAccepted, time: Exceeded} = state) do
    # enviar mensaje a taxista de tiempo excedido
    TaxiBeWeb.Endpoint.broadcast("driver:" <> driver_username, "booking_notification", %{msg: "Aceptacion demasiada tarde"})
    {:noreply, state}
  end

  # rechazo no modificar estado
  def handle_cast({:process_reject, driver_username}, state) do
    {:noreply, state}
  end

  # funciones auxiliares

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
