// SPDX-FileCopyrightText: 2019-Present Famedly GmbH
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:matrix/matrix.dart';
import 'package:matrix/src/voip/models/call_options.dart';
import 'package:test/test.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

import 'fake_client.dart';
import 'webrtc_stub.dart';

void main() {
  late Client client;
  late Room room;
  late VoIP voip;
  late _ControlledCandidateCall call;

  setUp(() async {
    Logs().level = Level.wtf;
    client = await getClient();
    await client.abortSync();
    voip = VoIP(client, MockWebRTCDelegate());
    room = client.getRoomById('!calls:example.com')!;
  });

  tearDown(() async {
    if (!call.callHasEnded) {
      await call.terminate(CallParty.kLocal, CallErrorCode.userHangup, false);
    }
    await client.dispose();
  });

  test('sends queued candidates once in generation order', () async {
    await _withManualCandidateTimers((_) async {
      call = await _createIncomingCall(voip, room, onSend: (_) async => 'sent');

      _emitCandidate(call, 'candidate-A');
      _emitCandidate(call, 'candidate-B');
      await call.answer();
      await _finishGathering(call);

      expect(call.sentCandidateNames, [
        <String>['candidate-A', 'candidate-B'],
      ]);
      expect(call.maxConcurrentSends, 1);
    });
  });

  test('retries a failed candidate batch without losing candidates', () async {
    await _withManualCandidateTimers((timers) async {
      var attempt = 0;
      call = await _createIncomingCall(
        voip,
        room,
        onSend: (_) async {
          attempt++;
          if (attempt == 1) throw StateError('candidate send failed');
          return 'sent';
        },
      );

      _emitCandidate(call, 'candidate-A');
      await call.answer();
      await _finishGathering(call);

      expect(call.sentCandidateNames, [
        <String>['candidate-A'],
      ]);
      timers.singleActive(const Duration(seconds: 1)).fire();
      await Future<void>.delayed(Duration.zero);

      expect(call.sentCandidateNames, [
        <String>['candidate-A'],
        <String>['candidate-A'],
      ]);
    });
  });

  test('preserves candidates arriving during a failed send', () async {
    await _withManualCandidateTimers((timers) async {
      final firstSend = Completer<String?>();
      final firstSendStarted = Completer<void>();
      var attempt = 0;
      call = await _createIncomingCall(
        voip,
        room,
        onSend: (_) {
          attempt++;
          if (attempt == 1) {
            firstSendStarted.complete();
            return firstSend.future;
          }
          return Future<String?>.value('sent');
        },
      );

      _emitCandidate(call, 'candidate-A');
      await call.answer();
      final gathering = _finishGathering(call);
      await firstSendStarted.future;
      _emitCandidate(call, 'candidate-B');
      firstSend.completeError(StateError('candidate send failed'));
      await gathering;

      timers.singleActive(const Duration(seconds: 1)).fire();
      await Future<void>.delayed(Duration.zero);

      expect(call.sentCandidateNames, [
        <String>['candidate-A'],
        <String>['candidate-A', 'candidate-B'],
      ]);
    });
  });

  test('serializes concurrent candidate send triggers', () async {
    await _withManualCandidateTimers((timers) async {
      final firstSend = Completer<String?>();
      final firstSendStarted = Completer<void>();
      call = await _createIncomingCall(
        voip,
        room,
        onSend: (_) {
          if (!firstSendStarted.isCompleted) {
            firstSendStarted.complete();
            return firstSend.future;
          }
          return Future<String?>.value('sent');
        },
      );

      _emitCandidate(call, 'candidate-A');
      await call.answer();
      final gathering = _finishGathering(call);
      await firstSendStarted.future;
      _emitCandidate(call, 'candidate-B');

      final delayedSend = timers.singleActive(
        const Duration(milliseconds: 500),
      );
      delayedSend.fire();
      await Future<void>.delayed(Duration.zero);

      try {
        expect(call.sendCount, 1);
        expect(call.maxConcurrentSends, 1);
      } finally {
        firstSend.complete('sent');
        await gathering;
      }

      expect(call.sentCandidateNames, [
        <String>['candidate-A'],
        <String>['candidate-B'],
      ]);
      expect(call.maxConcurrentSends, 1);
    });
  });

  test('resets retry state after a successful retry', () async {
    await _withManualCandidateTimers((timers) async {
      var attempt = 0;
      call = await _createIncomingCall(
        voip,
        room,
        onSend: (_) async {
          attempt++;
          if (attempt == 1) throw StateError('candidate send failed');
          return 'sent';
        },
      );

      _emitCandidate(call, 'candidate-A');
      await call.answer();
      await _finishGathering(call);
      timers.singleActive(const Duration(seconds: 1)).fire();
      await Future<void>.delayed(Duration.zero);

      _emitCandidate(call, 'candidate-B');
      timers.singleActive(const Duration(milliseconds: 500)).fire();
      await Future<void>.delayed(Duration.zero);

      expect(call.sentCandidateNames, [
        <String>['candidate-A'],
        <String>['candidate-A'],
        <String>['candidate-B'],
      ]);
    });
  });

  test('does not restore a failed batch from before an ICE restart', () async {
    await _withManualCandidateTimers((_) async {
      final firstSend = Completer<String?>();
      final firstSendStarted = Completer<void>();
      call = await _createIncomingCall(
        voip,
        room,
        onSend: (_) {
          if (!firstSendStarted.isCompleted) {
            firstSendStarted.complete();
            return firstSend.future;
          }
          return Future<String?>.value('sent');
        },
      );

      _emitCandidate(call, 'candidate-old');
      await call.answer();
      final gathering = _finishGathering(call);
      await firstSendStarted.future;

      await call.restartIce();
      _emitCandidate(call, 'candidate-new');
      firstSend.completeError(StateError('candidate send failed'));
      await gathering;

      expect(call.sentCandidateNames, [
        <String>['candidate-old'],
        <String>['candidate-new'],
      ]);
    });
  });

  test('cancels pending candidate retry during cleanup', () async {
    await _withManualCandidateTimers((timers) async {
      call = await _createIncomingCall(
        voip,
        room,
        onSend: (_) async => throw StateError('candidate send failed'),
      );

      _emitCandidate(call, 'candidate-A');
      await call.answer();
      await _finishGathering(call);
      final retry = timers.singleActive(const Duration(seconds: 1));

      await call.terminate(CallParty.kLocal, CallErrorCode.userHangup, false);

      expect(retry.isActive, isFalse);
      retry.fire();
      await Future<void>.delayed(Duration.zero);
      expect(call.sendCount, 1);
    });
  });
}

Future<_ControlledCandidateCall> _createIncomingCall(
  VoIP voip,
  Room room, {
  required _CandidateSend onSend,
}) async {
  final call = _ControlledCandidateCall(
    CallOptions(
      callId: 'candidate-queue-test',
      type: CallType.kVoice,
      dir: CallDirection.kIncoming,
      localPartyId: 'LOCAL_PARTY',
      voip: voip,
      room: room,
      iceServers: const [],
    ),
    onSend: onSend,
  );
  await call.initWithInvite(
    CallType.kVoice,
    RTCSessionDescription('offer-sdp', 'offer'),
    null,
    const Duration(minutes: 1).inMilliseconds,
    false,
  );
  return call;
}

void _emitCandidate(_ControlledCandidateCall call, String name) {
  call.pc!.onIceCandidate!(RTCIceCandidate(name, 'audio', 0));
}

Future<void> _finishGathering(_ControlledCandidateCall call) async {
  final result = call.pc!.onIceGatheringState!(
    RTCIceGatheringState.RTCIceGatheringStateComplete,
  );
  if (result is Future<void>) await result;
}

typedef _CandidateSend =
    Future<String?> Function(List<Map<String, dynamic>> candidates);

final class _ControlledCandidateCall extends CallSession {
  _ControlledCandidateCall(super.opts, {required this.onSend});

  final _CandidateSend onSend;
  final List<List<String>> sentCandidateNames = <List<String>>[];
  int sendCount = 0;
  int activeSends = 0;
  int maxConcurrentSends = 0;

  @override
  Future<String?> sendAnswerCall(
    Room room,
    String callId,
    String sdp,
    String partyId, {
    String type = 'answer',
    String version = voipProtoVersion,
    String? txid,
    CallCapabilities? capabilities,
    SDPStreamMetadata? metadata,
  }) async => 'answer-sent';

  @override
  Future<String?> sendCallCandidates(
    Room room,
    String callId,
    String partyId,
    List<Map<String, dynamic>> candidates, {
    String version = voipProtoVersion,
    String? txid,
  }) async {
    sendCount++;
    activeSends++;
    maxConcurrentSends = activeSends > maxConcurrentSends
        ? activeSends
        : maxConcurrentSends;
    sentCandidateNames.add(
      candidates.map((candidate) => candidate['candidate']! as String).toList(),
    );
    try {
      return await onSend(candidates);
    } finally {
      activeSends--;
    }
  }
}

Future<T> _withManualCandidateTimers<T>(
  Future<T> Function(_ManualTimerHarness timers) operation,
) {
  final timers = _ManualTimerHarness();
  return runZoned(
    () => operation(timers),
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (duration == const Duration(milliseconds: 500) ||
            duration.inSeconds >= 1 && duration.inSeconds <= 16) {
          return timers.create(duration, () => zone.runGuarded(callback));
        }
        return parent.createTimer(zone, duration, callback);
      },
    ),
  );
}

final class _ManualTimerHarness {
  final List<_ManualTimer> timers = <_ManualTimer>[];

  _ManualTimer create(Duration duration, void Function() callback) {
    final timer = _ManualTimer(duration, callback);
    timers.add(timer);
    return timer;
  }

  _ManualTimer singleActive(Duration duration) => timers.singleWhere(
    (timer) => timer.duration == duration && timer.isActive,
  );
}

final class _ManualTimer implements Timer {
  _ManualTimer(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  bool _isActive = true;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _isActive ? 0 : 1;

  @override
  void cancel() => _isActive = false;

  void fire() {
    if (!_isActive) return;
    _isActive = false;
    _callback();
  }
}
