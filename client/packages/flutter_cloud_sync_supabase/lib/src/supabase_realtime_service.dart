library;

import 'dart:async';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// Supabase implementation of [RealtimeChannel].
class SupabaseRealtimeChannel implements RealtimeChannel {
  final supabase.RealtimeChannel _channel;

  SupabaseRealtimeChannel(this._channel);

  @override
  RealtimeChannel onPostgresChanges({
    required String event,
    required String schema,
    required String table,
    String? filter,
    required void Function(Map<String, dynamic> payload) callback,
  }) {
    _channel.onPostgresChanges(
      event: _parsePostgresEvent(event),
      schema: schema,
      table: table,
      filter: filter != null
          ? supabase.PostgresChangeFilter(
              type: supabase.PostgresChangeFilterType.eq,
              column: filter.split('=').first,
              value: filter.split('=').last,
            )
          : null,
      callback: (payload) {
        // Convert Supabase payload to our format
        final data = <String, dynamic>{
          'eventType': payload.eventType.name.toUpperCase(),
          'new': payload.newRecord,
          'old': payload.oldRecord,
          'table': payload.table,
          'schema': payload.schema,
          'commitTimestamp': payload.commitTimestamp,
        };
        callback(data);
      },
    );

    return this;
  }

  @override
  RealtimeChannel on(
    String event,
    void Function(Map<String, dynamic> payload) callback,
  ) {
    _channel.onBroadcast(
      event: event,
      callback: (payload) {
        callback(payload);
      },
    );

    return this;
  }

  @override
  Future<void> send({
    required String event,
    required Map<String, dynamic> payload,
  }) async {
    await _channel.sendBroadcastMessage(
      event: event,
      payload: payload,
    );
  }

  @override
  Future<void> subscribe() async {
    await _channel.subscribe();
  }

  @override
  Future<void> unsubscribe() async {
    await supabase.Supabase.instance.client.removeChannel(_channel);
  }

  @override
  String get name => _channel.topic;

  @override
  String get state {
    // Supabase channel state is more complex, simplify it
    if (_channel.socket.isConnected) {
      return 'subscribed';
    }
    return 'closed';
  }

  /// Parse event string to Supabase event type
  supabase.PostgresChangeEvent _parsePostgresEvent(String event) {
    switch (event.toUpperCase()) {
      case 'INSERT':
        return supabase.PostgresChangeEvent.insert;
      case 'UPDATE':
        return supabase.PostgresChangeEvent.update;
      case 'DELETE':
        return supabase.PostgresChangeEvent.delete;
      case '*':
      case 'ALL':
        return supabase.PostgresChangeEvent.all;
      default:
        return supabase.PostgresChangeEvent.all;
    }
  }
}

/// Supabase implementation of [CloudRealtimeService].
///
/// Provides WebSocket-based realtime communication for Supabase.
///
/// Example:
/// ```dart
/// final client = supabase.Supabase.instance.client;
/// final realtimeService = SupabaseRealtimeService(client);
///
/// // Monitor connection state
/// realtimeService.connectionState.listen((state) {
///   print('Connection: $state');
/// });
///
/// // Create a channel
/// final channel = realtimeService.channel('transactions:123');
///
/// // Listen to database changes
/// channel.onPostgresChanges(
///   event: '*',
///   schema: 'public',
///   table: 'transactions',
///   filter: 'ledger_id=eq.123',
///   callback: (payload) {
///     print('Change: ${payload['eventType']}');
///   },
/// );
///
/// await channel.subscribe();
/// ```
class SupabaseRealtimeService implements CloudRealtimeService {
  final supabase.SupabaseClient _client;
  final Map<String, RealtimeChannel> _channels = {};
  final StreamController<RealtimeConnectionState> _connectionStateController =
      StreamController<RealtimeConnectionState>.broadcast();

  RealtimeConnectionState _currentState = RealtimeConnectionState.disconnected;

  SupabaseRealtimeService(this._client) {
    _initializeConnectionMonitoring();
  }

  /// Initialize connection state monitoring
  void _initializeConnectionMonitoring() {
    // Monitor Supabase realtime connection status
    // Note: Supabase doesn't expose a direct connection state stream
    // We infer state from channel subscriptions and socket events
    _updateConnectionState(
      _client.realtime.isConnected
          ? RealtimeConnectionState.connected
          : RealtimeConnectionState.disconnected,
    );
  }

  @override
  Stream<RealtimeConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override
  RealtimeConnectionState get currentState => _currentState;

  @override
  RealtimeChannel channel(String channelName) {
    // Return existing channel if already created
    if (_channels.containsKey(channelName)) {
      return _channels[channelName]!;
    }

    // Create new Supabase channel
    final supabaseChannel = _client.channel(channelName);

    // Wrap in our interface
    final channel = SupabaseRealtimeChannel(supabaseChannel);

    // Cache channel
    _channels[channelName] = channel;

    return channel;
  }

  @override
  Future<void> removeChannel(String channelName) async {
    final channel = _channels.remove(channelName);
    if (channel != null) {
      await channel.unsubscribe();
    }
  }

  @override
  Future<void> removeAllChannels() async {
    for (final channel in _channels.values) {
      await channel.unsubscribe();
    }
    _channels.clear();
  }

  @override
  List<RealtimeChannel> get channels => _channels.values.toList();

  @override
  bool hasChannel(String channelName) => _channels.containsKey(channelName);

  @override
  Future<void> connect() async {
    _updateConnectionState(RealtimeConnectionState.connecting);

    try {
      // Supabase realtime connection is automatic
      // Just ensure client is initialized
      if (!_client.realtime.isConnected) {
        // Connection will be established when first channel subscribes
        _updateConnectionState(RealtimeConnectionState.connected);
      } else {
        _updateConnectionState(RealtimeConnectionState.connected);
      }
    } catch (e) {
      _updateConnectionState(RealtimeConnectionState.error);
      throw CloudSyncException('Failed to connect to realtime server: $e');
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      // Remove all channels
      await removeAllChannels();

      // Disconnect realtime
      // Note: Supabase doesn't provide explicit disconnect
      // Channels are automatically cleaned up

      _updateConnectionState(RealtimeConnectionState.disconnected);
    } catch (e) {
      _updateConnectionState(RealtimeConnectionState.error);
      throw CloudSyncException('Failed to disconnect from realtime server: $e');
    }
  }

  /// Update connection state and notify listeners
  void _updateConnectionState(RealtimeConnectionState newState) {
    if (_currentState != newState) {
      _currentState = newState;
      _connectionStateController.add(_currentState);
    }
  }

  /// Dispose resources
  void dispose() {
    _connectionStateController.close();
  }
}
