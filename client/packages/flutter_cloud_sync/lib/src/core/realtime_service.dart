/// Cloud Realtime Service
///
/// Abstract interface for realtime communication (WebSocket-based).
/// Supports both database change subscriptions and custom events.
library;

/// Realtime connection state
enum RealtimeConnectionState {
  /// Connecting to server
  connecting,

  /// Connected and ready
  connected,

  /// Disconnected
  disconnected,

  /// Connection error
  error,
}

/// Realtime channel
///
/// Represents a pub/sub channel for realtime communication.
///
/// Example:
/// ```dart
/// final channel = realtimeService.channel('room:123')
///   .onPostgresChanges(
///     event: 'INSERT',
///     schema: 'public',
///     table: 'messages',
///     filter: 'room_id=eq.123',
///     callback: (payload) {
///       print('New message: ${payload['new']}');
///     },
///   )
///   .on('custom-event', (payload) {
///     print('Custom event: $payload');
///   });
///
/// await channel.subscribe();
///
/// // Send custom event
/// await channel.send(
///   event: 'user-typing',
///   payload: {'user': 'John'},
/// );
///
/// // Clean up
/// await channel.unsubscribe();
/// ```
abstract class RealtimeChannel {
  /// Subscribe to PostgreSQL database changes
  ///
  /// - [event]: Event type (INSERT, UPDATE, DELETE, or * for all)
  /// - [schema]: Database schema (usually 'public')
  /// - [table]: Table name
  /// - [filter]: Optional filter (e.g., 'user_id=eq.123')
  /// - [callback]: Function called when event occurs
  RealtimeChannel onPostgresChanges({
    required String event,
    required String schema,
    required String table,
    String? filter,
    required void Function(Map<String, dynamic> payload) callback,
  });

  /// Subscribe to custom events (broadcast)
  ///
  /// - [event]: Event name
  /// - [callback]: Function called when event occurs
  RealtimeChannel on(
    String event,
    void Function(Map<String, dynamic> payload) callback,
  );

  /// Send a custom event to all subscribers
  ///
  /// - [event]: Event name
  /// - [payload]: Event data
  Future<void> send({
    required String event,
    required Map<String, dynamic> payload,
  });

  /// Subscribe to the channel
  ///
  /// Must be called after setting up listeners.
  Future<void> subscribe();

  /// Unsubscribe from the channel
  ///
  /// Removes all listeners and closes the channel.
  Future<void> unsubscribe();

  /// Channel name
  String get name;

  /// Channel state
  String get state;
}

/// Cloud realtime service interface
///
/// Provides realtime communication capabilities using WebSockets.
///
/// Example:
/// ```dart
/// final realtimeService = SupabaseRealtimeProvider(client);
///
/// // Monitor connection state
/// realtimeService.connectionState.listen((state) {
///   print('Realtime connection: $state');
/// });
///
/// // Create a channel
/// final channel = realtimeService.channel('my-channel');
///
/// // Listen to database changes
/// channel.onPostgresChanges(
///   event: '*',
///   schema: 'public',
///   table: 'transactions',
///   filter: 'ledger_id=eq.${ledgerId}',
///   callback: (payload) {
///     final eventType = payload['eventType']; // INSERT, UPDATE, DELETE
///     final record = payload['new'] ?? payload['old'];
///     print('$eventType: $record');
///   },
/// );
///
/// await channel.subscribe();
/// ```
abstract class CloudRealtimeService {
  /// Connection state stream
  ///
  /// Emits connection state changes.
  Stream<RealtimeConnectionState> get connectionState;

  /// Current connection state
  RealtimeConnectionState get currentState;

  /// Create or get a realtime channel
  ///
  /// Channels are cached by name. Multiple calls with the same name
  /// return the same channel instance.
  ///
  /// - [channelName]: Unique channel identifier
  RealtimeChannel channel(String channelName);

  /// Remove a specific channel
  ///
  /// Unsubscribes and removes the channel from cache.
  Future<void> removeChannel(String channelName);

  /// Remove all channels
  ///
  /// Unsubscribes and removes all channels.
  Future<void> removeAllChannels();

  /// Get all active channels
  List<RealtimeChannel> get channels;

  /// Check if a channel exists
  bool hasChannel(String channelName);

  /// Connect to realtime server
  ///
  /// Usually called automatically when creating the first channel.
  Future<void> connect();

  /// Disconnect from realtime server
  ///
  /// Removes all channels and closes the connection.
  Future<void> disconnect();
}
