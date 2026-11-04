// SPDX-FileCopyrightText: 2019-Present Famedly GmbH
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:matrix/src/voip/models/call_options.dart';
import 'package:matrix/src/voip/models/voip_id.dart';
import 'package:test/test.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

import 'fake_client.dart';
import 'webrtc_stub.dart';

void main() {
  late Client client;
  late Room room;
  late _ControlledVoIP voip;
  late _CapturingWebRTCDelegate delegate;
  late _ControlledCandidateCall call;

  setUp(() async {
    Logs().level = Level.wtf;
    client = await getClient();
    await client.abortSync();
    delegate = _CapturingWebRTCDelegate();
    voip = _ControlledVoIP(client, delegate);
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
      final events = _observeDiagnostics(call);

      _emitCandidate(call, 'candidate-A');
      _emitCandidate(call, 'candidate-B');
      await call.answer();
      await _finishGathering(call);
      await _flushDiagnostics();

      expect(call.sentCandidateNames, [
        <String>['candidate-A', 'candidate-B'],
      ]);
      expect(call.maxConcurrentSends, 1);
      expect(
        events,
        containsAllInOrder(<CallSessionDiagnosticEvent>[
          CallSessionDiagnosticEvent.localCandidateGeneratedUnknown,
          CallSessionDiagnosticEvent.localCandidateGeneratedUnknown,
          CallSessionDiagnosticEvent.answerSignalingStarted,
          CallSessionDiagnosticEvent.answerSignalingSucceeded,
          CallSessionDiagnosticEvent.localCandidateBatchQueued,
          CallSessionDiagnosticEvent.localCandidateSendStarted,
          CallSessionDiagnosticEvent.localCandidateSendSucceeded,
        ]),
      );
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
      final events = _observeDiagnostics(call);

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
      expect(
        events,
        containsAllInOrder(<CallSessionDiagnosticEvent>[
          CallSessionDiagnosticEvent.localCandidateSendFailed,
          CallSessionDiagnosticEvent.localCandidateRetryAttempted,
          CallSessionDiagnosticEvent.localCandidateSendStarted,
          CallSessionDiagnosticEvent.localCandidateSendSucceeded,
        ]),
      );
    });
  });

  final candidateFailures =
      <({Object error, CallSessionDiagnosticEvent event})>[
        (
          error: TimeoutException('candidate timeout'),
          event: CallSessionDiagnosticEvent.localCandidateSendTimedOut,
        ),
        (
          error: MatrixException.fromJson(<String, Object?>{
            'errcode': 'M_LIMIT_EXCEEDED',
          }),
          event: CallSessionDiagnosticEvent.localCandidateSendRateLimited,
        ),
        (
          error: MatrixException.fromJson(<String, Object?>{
            'errcode': 'M_FORBIDDEN',
          }),
          event: CallSessionDiagnosticEvent.localCandidateSendRejected,
        ),
        (
          error: http.ClientException('transport failed'),
          event: CallSessionDiagnosticEvent.localCandidateSendTransportFailed,
        ),
        (
          error: StateError('unclassified failure'),
          event: CallSessionDiagnosticEvent.localCandidateSendUnknownFailed,
        ),
      ];
  for (final (:error, :event) in candidateFailures) {
    test('classifies candidate send failure as ${event.name}', () async {
      await _withManualCandidateTimers((_) async {
        call = await _createIncomingCall(
          voip,
          room,
          onSend: (_) async => throw error,
        );
        final events = _observeDiagnostics(call);

        _emitCandidate(call, 'candidate-A');
        await call.answer();
        await _finishGathering(call);
        await _flushDiagnostics();

        expect(
          events,
          containsAllInOrder(<CallSessionDiagnosticEvent>[
            CallSessionDiagnosticEvent.localCandidateSendFailed,
            event,
          ]),
        );
      });
    });
  }

  test('reports permanent candidate send exhaustion', () async {
    await _withManualCandidateTimers((timers) async {
      call = await _createIncomingCall(
        voip,
        room,
        onSend: (_) async => throw TimeoutException('candidate timeout'),
      );
      final events = _observeDiagnostics(call);

      _emitCandidate(call, 'candidate-A');
      await call.answer();
      await _finishGathering(call);
      for (final delay in <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
        const Duration(seconds: 8),
        const Duration(seconds: 16),
      ]) {
        timers.singleActive(delay).fire();
        await Future<void>.delayed(Duration.zero);
      }

      expect(call.callHasEnded, isTrue);
      expect(
        events,
        contains(CallSessionDiagnosticEvent.localCandidateRetriesExhausted),
      );
    });
  });

  test('reports a remote terminal boundary before cleanup', () async {
    call = await _createIncomingCall(voip, room, onSend: (_) async => 'sent');
    final events = _observeDiagnostics(call);

    await call.terminate(CallParty.kRemote, CallErrorCode.userHangup, false);

    expect(
      events,
      contains(CallSessionDiagnosticEvent.remoteTerminationReceived),
    );
  });

  test('reports outgoing invite signaling boundaries', () async {
    call =
        await voip.inviteToCall(room, CallType.kVoice)
            as _ControlledCandidateCall;
    await call.onNegotiationNeeded();
    await _flushDiagnostics();

    expect(
      delegate.events,
      containsAllInOrder(<CallSessionDiagnosticEvent>[
        CallSessionDiagnosticEvent.inviteSignalingStarted,
        CallSessionDiagnosticEvent.inviteSignalingSucceeded,
      ]),
    );
  });

  test('incoming media is acquired only when the call is answered', () async {
    call = await _createIncomingCall(voip, room, onSend: (_) async => 'sent');

    expect(delegate.trackingMediaDevices.userMediaRequests, 0);

    await call.answer();

    expect(delegate.trackingMediaDevices.userMediaRequests, 1);
  });

  test(
    'termination during incoming media acquisition disposes the stream',
    () async {
      final mediaGate = Completer<void>();
      delegate.trackingMediaDevices.gate = mediaGate;
      call = await _createIncomingCall(voip, room, onSend: (_) async => 'sent');

      final answering = call.answer();
      await delegate.trackingMediaDevices.requestStarted.future;
      await call.hangup(reason: CallErrorCode.userHangup, shouldEmit: false);
      mediaGate.complete();
      await answering;

      expect(delegate.trackingMediaDevices.lastStream?.active, isFalse);
      expect(call.state, CallState.kEnded);
    },
  );

  test('concurrent answers acquire incoming media only once', () async {
    final mediaGate = Completer<void>();
    delegate.trackingMediaDevices.gate = mediaGate;
    call = await _createIncomingCall(voip, room, onSend: (_) async => 'sent');

    final firstAnswer = call.answer();
    await delegate.trackingMediaDevices.requestStarted.future;
    final secondAnswer = call.answer();
    await Future<void>.delayed(Duration.zero);

    expect(delegate.trackingMediaDevices.userMediaRequests, 1);

    mediaGate.complete();
    await Future.wait<void>(<Future<void>>[firstAnswer, secondAnswer]);
    expect(delegate.trackingMediaDevices.userMediaRequests, 1);
  });

  test('reports only the coarse local candidate type', () async {
    await _withManualCandidateTimers((_) async {
      call = await _createIncomingCall(voip, room, onSend: (_) async => 'sent');
      final events = _observeDiagnostics(call);

      _emitCandidate(call, 'candidate:1 1 udp 1 192.0.2.10 10000 typ host');
      _emitCandidate(call, 'candidate:2 1 udp 1 198.51.100.10 10001 typ srflx');
      _emitCandidate(call, 'candidate:3 1 udp 1 203.0.113.10 10002 typ prflx');
      _emitCandidate(call, 'candidate:4 1 udp 1 203.0.113.20 10003 typ relay');
      await _flushDiagnostics();

      expect(events, <CallSessionDiagnosticEvent>[
        CallSessionDiagnosticEvent.localHostCandidateGenerated,
        CallSessionDiagnosticEvent.localServerReflexiveCandidateGenerated,
        CallSessionDiagnosticEvent.localPeerReflexiveCandidateGenerated,
        CallSessionDiagnosticEvent.localRelayCandidateGenerated,
      ]);
      expect(events.join(','), isNot(contains('192.0.2.10')));
      expect(events.join(','), isNot(contains('203.0.113.20')));
    });
  });

  test('reports remote candidate queueing and application', () async {
    await _withManualCandidateTimers((_) async {
      call = await _createIncomingCall(voip, room, onSend: (_) async => 'sent');
      final peerConnection = _TrackingPeerConnection();
      call.pc = peerConnection;
      final events = _observeDiagnostics(call);
      final applied = call.onCallDiagnosticEvent.firstWhere(
        (event) => event == CallSessionDiagnosticEvent.remoteCandidateApplied,
      );

      await call.onCandidatesReceived(<Map<String, dynamic>>[
        <String, dynamic>{
          'candidate': 'candidate:1 1 udp 1 203.0.113.20 10003 typ relay',
          'sdpMid': 'audio',
          'sdpMLineIndex': 0,
        },
      ]);
      await call.answer();
      await applied;

      expect(
        events,
        containsAllInOrder(<CallSessionDiagnosticEvent>[
          CallSessionDiagnosticEvent.remoteCandidateBatchReceived,
          CallSessionDiagnosticEvent.remoteCandidateQueued,
          CallSessionDiagnosticEvent.remoteCandidateApplied,
        ]),
      );
      expect(peerConnection.appliedCandidates, hasLength(1));
    });
  });

  test(
    'applies a remote candidate arriving while answer is in flight',
    () async {
      await _withManualCandidateTimers((_) async {
        final answerStarted = Completer<void>();
        final releaseAnswer = Completer<String?>();
        call = await _createIncomingCall(
          voip,
          room,
          onSend: (_) async => 'sent',
          onAnswer: () {
            answerStarted.complete();
            return releaseAnswer.future;
          },
        );
        final events = _observeDiagnostics(call);

        final answering = call.answer();
        await answerStarted.future;
        await call.onCandidatesReceived(<Map<String, dynamic>>[
          <String, dynamic>{
            'candidate': 'candidate:1 1 udp 1 203.0.113.20 10003 typ relay',
            'sdpMid': 'audio',
            'sdpMLineIndex': 0,
          },
        ]);
        releaseAnswer.complete('answer-sent');
        await answering;
        await _flushDiagnostics();

        expect(
          events,
          containsAllInOrder(<CallSessionDiagnosticEvent>[
            CallSessionDiagnosticEvent.remoteCandidateBatchReceived,
            CallSessionDiagnosticEvent.remoteCandidateQueued,
            CallSessionDiagnosticEvent.remoteCandidateApplied,
          ]),
        );
      });
    },
  );

  test(
    'recovers candidates received before the incoming session exists',
    () async {
      await _deliverCandidateSync(
        client,
        room,
        callId: 'candidate-before-invite',
        partyId: 'ALICE_PARTY',
        candidate: 'candidate:1 1 udp 1 203.0.113.20 10003 typ relay',
      );

      await voip.onCallInvite(
        room,
        '@alice:example.com',
        'ALICE_DEVICE',
        <String, dynamic>{
          'lifetime': const Duration(minutes: 1).inMilliseconds,
          'call_id': 'candidate-before-invite',
          'party_id': 'ALICE_PARTY',
          'version': '1',
          'offer': <String, dynamic>{'type': 'offer', 'sdp': 'offer-sdp'},
        },
      );
      call = voip.latestCall!;
      await call.answer();
      await _flushDiagnostics();

      expect(
        delegate.events,
        containsAllInOrder(<CallSessionDiagnosticEvent>[
          CallSessionDiagnosticEvent.remoteCandidateBatchRecoveredBeforeSession,
          CallSessionDiagnosticEvent.remoteCandidateBatchReceived,
          CallSessionDiagnosticEvent.remoteCandidateQueued,
          CallSessionDiagnosticEvent.remoteDescriptionReady,
          CallSessionDiagnosticEvent.remoteCandidateQueueFlushStarted,
          CallSessionDiagnosticEvent.remoteCandidateApplied,
          CallSessionDiagnosticEvent.remoteCandidateQueueFlushSucceeded,
        ]),
      );
    },
  );

  test(
    'does not apply stale buffered candidates to a rapid replacement call',
    () async {
      await voip.onCallCandidates(room, <String, dynamic>{
        'call_id': 'old-call',
        'candidates': <Map<String, dynamic>>[
          <String, dynamic>{
            'candidate': 'candidate:1 1 udp 1 192.0.2.10 10000 typ host',
            'sdpMid': 'audio',
            'sdpMLineIndex': 0,
          },
        ],
      });
      await voip.onCallHangup(room, <String, dynamic>{
        'call_id': 'old-call',
        'reason': 'user_hangup',
      });
      await voip.onCallCandidates(room, <String, dynamic>{
        'call_id': 'new-call',
        'candidates': <Map<String, dynamic>>[
          <String, dynamic>{
            'candidate': 'candidate:2 1 udp 1 203.0.113.20 10003 typ relay',
            'sdpMid': 'audio',
            'sdpMLineIndex': 0,
          },
        ],
      });

      await voip.onCallInvite(
        room,
        '@alice:example.com',
        'ALICE_DEVICE',
        <String, dynamic>{
          'lifetime': const Duration(minutes: 1).inMilliseconds,
          'call_id': 'new-call',
          'party_id': 'ALICE_PARTY',
          'version': '1',
          'offer': <String, dynamic>{'type': 'offer', 'sdp': 'offer-sdp'},
        },
      );
      call = voip.latestCall!;
      await call.answer();

      expect(
        delegate.latestPeerConnection!.appliedCandidates.map(
          (candidate) => candidate.candidate,
        ),
        <String>['candidate:2 1 udp 1 203.0.113.20 10003 typ relay'],
      );
    },
  );

  test('rejects pre-session candidates from a different sender', () async {
    await _deliverCandidateSync(
      client,
      room,
      callId: 'sender-mismatch',
      partyId: 'MALLORY_PARTY',
      candidate: 'candidate:1 1 udp 1 192.0.2.10 10000 typ host',
      senderId: '@mallory:example.com',
    );

    await voip.onCallInvite(
      room,
      '@alice:example.com',
      'ALICE_DEVICE',
      <String, dynamic>{
        'lifetime': const Duration(minutes: 1).inMilliseconds,
        'call_id': 'sender-mismatch',
        'party_id': 'ALICE_PARTY',
        'version': '1',
        'offer': <String, dynamic>{'type': 'offer', 'sdp': 'offer-sdp'},
      },
    );
    call = voip.latestCall!;
    await call.answer();

    expect(delegate.latestPeerConnection!.appliedCandidates, isEmpty);
    expect(
      delegate.events,
      isNot(
        contains(
          CallSessionDiagnosticEvent.remoteCandidateBatchRecoveredBeforeSession,
        ),
      ),
    );
  });

  test('expires candidates when the invite never materializes', () async {
    await _withManualCandidateTimers((timers) async {
      await voip.onCallCandidates(room, <String, dynamic>{
        'call_id': 'expired-buffer',
        'candidates': <Map<String, dynamic>>[
          <String, dynamic>{
            'candidate': 'candidate:1 1 udp 1 192.0.2.10 10000 typ host',
            'sdpMid': 'audio',
            'sdpMLineIndex': 0,
          },
        ],
      });
      timers.singleActive(const Duration(seconds: 60)).fire();

      await voip.onCallInvite(
        room,
        '@alice:example.com',
        'ALICE_DEVICE',
        <String, dynamic>{
          'lifetime': const Duration(minutes: 1).inMilliseconds,
          'call_id': 'expired-buffer',
          'party_id': 'ALICE_PARTY',
          'version': '1',
          'offer': <String, dynamic>{'type': 'offer', 'sdp': 'offer-sdp'},
        },
      );
      call = voip.latestCall!;
      await call.answer();

      expect(delegate.latestPeerConnection!.appliedCandidates, isEmpty);
      expect(
        delegate.events,
        isNot(
          contains(
            CallSessionDiagnosticEvent
                .remoteCandidateBatchRecoveredBeforeSession,
          ),
        ),
      );
    });
  });

  test('bounds orphaned candidate sessions by evicting the oldest', () async {
    await _withManualCandidateTimers((_) async {
      for (var index = 0; index < 9; index++) {
        await voip.onCallCandidates(room, <String, dynamic>{
          'call_id': 'bounded-call-$index',
          'candidates': <Map<String, dynamic>>[
            <String, dynamic>{
              'candidate': 'candidate:$index 1 udp 1 192.0.2.10 10000 typ host',
              'sdpMid': 'audio',
              'sdpMLineIndex': 0,
            },
          ],
        });
      }

      await _inviteIncoming(voip, room, callId: 'bounded-call-0');
      call = voip.latestCall!;
      await call.answer();

      expect(delegate.latestPeerConnection!.appliedCandidates, isEmpty);
    });
  });

  test('bounds candidates retained for one pending session', () async {
    await _withManualCandidateTimers((_) async {
      await voip.onCallCandidates(room, <String, dynamic>{
        'call_id': 'bounded-candidates',
        'candidates': List<Map<String, dynamic>>.generate(
          65,
          (index) => <String, dynamic>{
            'candidate': 'candidate:$index 1 udp 1 192.0.2.10 10000 typ host',
            'sdpMid': 'audio',
            'sdpMLineIndex': 0,
          },
        ),
      });

      await _inviteIncoming(voip, room, callId: 'bounded-candidates');
      call = voip.latestCall!;
      await call.answer();

      expect(delegate.latestPeerConnection!.appliedCandidates, hasLength(64));
    });
  });

  test(
    'reports remote candidate application failure without changing behavior',
    () async {
      await _withManualCandidateTimers((_) async {
        call = await _createIncomingCall(
          voip,
          room,
          onSend: (_) async => 'sent',
        );
        call.pc = _FailingCandidatePeerConnection();
        final events = _observeDiagnostics(call);

        await call.answer();
        await expectLater(
          call.onCandidatesReceived(<Map<String, dynamic>>[
            <String, dynamic>{
              'candidate': 'candidate:1 1 udp 1 203.0.113.20 10003 typ relay',
              'sdpMid': 'audio',
              'sdpMLineIndex': 0,
            },
          ]),
          completes,
        );
        await _flushDiagnostics();

        expect(
          events,
          containsAllInOrder(<CallSessionDiagnosticEvent>[
            CallSessionDiagnosticEvent.remoteCandidateBatchReceived,
            CallSessionDiagnosticEvent.remoteCandidateApplicationFailed,
          ]),
        );
      });
    },
  );

  test('reports ICE restart boundaries', () async {
    await _withManualCandidateTimers((_) async {
      call = await _createIncomingCall(voip, room, onSend: (_) async => 'sent');
      final events = _observeDiagnostics(call);

      await call.restartIce();
      await _flushDiagnostics();

      expect(events, <CallSessionDiagnosticEvent>[
        CallSessionDiagnosticEvent.iceRestartStarted,
        CallSessionDiagnosticEvent.iceRestartCompleted,
      ]);
    });
  });

  test(
    'reports failed answer signaling without changing the failure',
    () async {
      await _withManualCandidateTimers((_) async {
        call = await _createIncomingCall(
          voip,
          room,
          onSend: (_) async => 'sent',
          failAnswer: true,
        );
        final events = _observeDiagnostics(call);

        await expectLater(call.answer(), throwsStateError);
        await _flushDiagnostics();

        expect(
          events,
          containsAllInOrder(<CallSessionDiagnosticEvent>[
            CallSessionDiagnosticEvent.answerSignalingStarted,
            CallSessionDiagnosticEvent.answerSignalingFailed,
          ]),
        );
      });
    },
  );

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

  test('late ICE connected event cannot resurrect a terminated call', () async {
    call = await _createIncomingCall(voip, room, onSend: (_) async => 'sent');
    final connection = call.pc!;

    await call.terminate(CallParty.kLocal, CallErrorCode.userHangup, false);
    final callback = connection.onIceConnectionState!(
      RTCIceConnectionState.RTCIceConnectionStateConnected,
    );
    if (callback is Future<void>) await callback;

    expect(call.state, CallState.kEnded);
  });

  test('late ICE failure cannot restart a terminated call', () async {
    call = await _createIncomingCall(voip, room, onSend: (_) async => 'sent');
    final connection = call.pc!;
    final events = _observeDiagnostics(call);

    await call.terminate(CallParty.kLocal, CallErrorCode.userHangup, false);
    final callback = connection.onIceConnectionState!(
      RTCIceConnectionState.RTCIceConnectionStateFailed,
    );
    if (callback is Future<void>) await callback;

    expect(
      events,
      isNot(contains(CallSessionDiagnosticEvent.iceRestartStarted)),
    );
  });

  test('termination contains an overlapping ICE restart failure', () async {
    call = await _createIncomingCall(voip, room, onSend: (_) async => 'sent');
    final connection = call.pc! as _TrackingPeerConnection;
    final restartGate = Completer<void>();
    connection
      ..restartGate = restartGate
      ..throwAfterRestartGate = true;

    final callback =
        connection.onIceConnectionState!(
              RTCIceConnectionState.RTCIceConnectionStateFailed,
            )!
            as Future<void>;
    await connection.restartStarted.future;
    await call.terminate(CallParty.kLocal, CallErrorCode.userHangup, false);
    restartGate.complete();

    await expectLater(callback, completes);
    expect(call.state, CallState.kEnded);
  });

  test(
    'hangup forwards the protocol reason and surfaces final failure',
    () async {
      String? observedReason;
      call = await _createIncomingCall(
        voip,
        room,
        onSend: (_) async => 'sent',
        onHangup: (reason, _) async {
          observedReason = reason;
          throw StateError('terminal signaling failed');
        },
      );

      await expectLater(
        call.hangup(reason: CallErrorCode.iceTimeout),
        throwsStateError,
      );

      expect(observedReason, CallErrorCode.iceTimeout.reason);
      expect(call.state, CallState.kEnded);
    },
  );

  test(
    'hangup retries one rate-limited request with the same transaction',
    () async {
      final transactions = <String?>[];
      var attempts = 0;
      call = await _createIncomingCall(
        voip,
        room,
        onSend: (_) async => 'sent',
        onHangup: (_, txid) async {
          transactions.add(txid);
          attempts++;
          if (attempts == 1) {
            throw MatrixException.fromJson(<String, Object?>{
              'errcode': 'M_LIMIT_EXCEEDED',
              'retry_after_ms': 0,
            });
          }
          return 'sent';
        },
      );

      await call.hangup(reason: CallErrorCode.userHangup);

      expect(attempts, 2);
      expect(transactions.first, isNotNull);
      expect(transactions.toSet(), hasLength(1));
    },
  );

  test('hangup with emission disabled performs local cleanup only', () async {
    var sends = 0;
    call = await _createIncomingCall(
      voip,
      room,
      onSend: (_) async => 'sent',
      onHangup: (_, _) async {
        sends++;
        return 'sent';
      },
    );

    await call.hangup(reason: CallErrorCode.userHangup, shouldEmit: false);

    expect(sends, 0);
    expect(call.state, CallState.kEnded);
  });

  test('reject uses the bounded rate-limit retry path', () async {
    var attempts = 0;
    call = await _createIncomingCall(
      voip,
      room,
      onSend: (_) async => 'sent',
      onReject: (_) async {
        attempts++;
        if (attempts == 1) {
          throw MatrixException.fromJson(<String, Object?>{
            'errcode': 'M_LIMIT_EXCEEDED',
            'retry_after_ms': 0,
          });
        }
        return 'sent';
      },
    );

    await call.reject();

    expect(attempts, 2);
    expect(call.state, CallState.kEnded);
  });
}

Future<_ControlledCandidateCall> _createIncomingCall(
  VoIP voip,
  Room room, {
  required _CandidateSend onSend,
  bool failAnswer = false,
  Future<String?> Function()? onAnswer,
  Future<String?> Function(String? reason, String? txid)? onHangup,
  Future<String?> Function(String? txid)? onReject,
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
    failAnswer: failAnswer,
    onAnswer: onAnswer,
    onHangup: onHangup,
    onReject: onReject,
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

List<CallSessionDiagnosticEvent> _observeDiagnostics(CallSession call) {
  final events = <CallSessionDiagnosticEvent>[];
  call.onCallDiagnosticEvent.listen(events.add);
  return events;
}

Future<void> _flushDiagnostics() => Future<void>.delayed(Duration.zero);

Future<void> _deliverCandidateSync(
  Client client,
  Room room, {
  required String callId,
  required String partyId,
  required String candidate,
  String senderId = '@alice:example.com',
}) async {
  await client.handleSync(
    SyncUpdate(
      nextBatch: 'candidate-before-invite',
      rooms: RoomsUpdate(
        join: <String, JoinedRoomUpdate>{
          room.id: JoinedRoomUpdate(
            timeline: TimelineUpdate(
              events: <MatrixEvent>[
                MatrixEvent(
                  type: EventTypes.CallCandidates,
                  content: <String, dynamic>{
                    'call_id': callId,
                    'party_id': partyId,
                    'version': '1',
                    'candidates': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'candidate': candidate,
                        'sdpMid': 'audio',
                        'sdpMLineIndex': 0,
                      },
                    ],
                  },
                  senderId: senderId,
                  eventId: 'candidate-$callId',
                  originServerTs: DateTime.now(),
                ),
              ],
            ),
          ),
        },
      ),
    ),
  );
  await Future<void>.delayed(Duration.zero);
}

Future<void> _inviteIncoming(VoIP voip, Room room, {required String callId}) =>
    voip.onCallInvite(
      room,
      '@alice:example.com',
      'ALICE_DEVICE',
      <String, dynamic>{
        'lifetime': const Duration(minutes: 1).inMilliseconds,
        'call_id': callId,
        'party_id': 'ALICE_PARTY',
        'version': '1',
        'offer': <String, dynamic>{'type': 'offer', 'sdp': 'offer-sdp'},
      },
    );

Future<void> _finishGathering(_ControlledCandidateCall call) async {
  final result = call.pc!.onIceGatheringState!(
    RTCIceGatheringState.RTCIceGatheringStateComplete,
  );
  if (result is Future<void>) await result;
}

typedef _CandidateSend =
    Future<String?> Function(List<Map<String, dynamic>> candidates);

final class _ControlledCandidateCall extends CallSession {
  _ControlledCandidateCall(
    super.opts, {
    required this.onSend,
    required this.failAnswer,
    this.onAnswer,
    this.onHangup,
    this.onReject,
  });

  final _CandidateSend onSend;
  final bool failAnswer;
  final Future<String?> Function()? onAnswer;
  final Future<String?> Function(String? reason, String? txid)? onHangup;
  final Future<String?> Function(String? txid)? onReject;
  final List<List<String>> sentCandidateNames = <List<String>>[];
  int sendCount = 0;
  int activeSends = 0;
  int maxConcurrentSends = 0;

  @override
  Future<String?> sendInviteToCall(
    Room room,
    String callId,
    int lifetime,
    String partyId,
    String sdp, {
    String type = 'offer',
    String version = voipProtoVersion,
    String? txid,
    CallCapabilities? capabilities,
    SDPStreamMetadata? metadata,
  }) async => 'invite-sent';

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
  }) async {
    if (failAnswer) throw StateError('answer signaling failed');
    if (onAnswer != null) return onAnswer!();
    return 'answer-sent';
  }

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

  @override
  Future<String?> sendHangupCall(
    Room room,
    String callId,
    String partyId,
    String? hangupCause, {
    String version = voipProtoVersion,
    String? txid,
  }) {
    final callback = onHangup;
    if (callback != null) return callback(hangupCause, txid);
    return Future<String?>.value('hangup-sent');
  }

  @override
  Future<String?> sendCallReject(
    Room room,
    String callId,
    String partyId, {
    String version = voipProtoVersion,
    String? txid,
  }) {
    final callback = onReject;
    if (callback != null) return callback(txid);
    return Future<String?>.value('reject-sent');
  }
}

final class _ControlledVoIP extends VoIP {
  _ControlledVoIP(super.client, super.delegate);

  _ControlledCandidateCall? latestCall;

  @override
  CallSession createNewCall(CallOptions opts) {
    final call = _ControlledCandidateCall(
      opts,
      onSend: (_) async => 'sent',
      failAnswer: false,
    );
    calls[VoipId(roomId: opts.room.id, callId: opts.callId)] = call;
    latestCall = call;
    return call;
  }
}

final class _CapturingWebRTCDelegate extends MockWebRTCDelegate {
  final List<CallSessionDiagnosticEvent> events =
      <CallSessionDiagnosticEvent>[];
  final _TrackingMediaDevices trackingMediaDevices = _TrackingMediaDevices();
  _TrackingPeerConnection? latestPeerConnection;

  @override
  MediaDevices get mediaDevices => trackingMediaDevices;

  @override
  Future<RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration, [
    Map<String, dynamic> constraints = const <String, dynamic>{},
  ]) async => latestPeerConnection = _TrackingPeerConnection();

  @override
  Future<void> registerListeners(CallSession session) async {
    session.onCallDiagnosticEvent.listen(events.add);
    await super.registerListeners(session);
  }
}

final class _TrackingMediaDevices extends MockMediaDevices {
  int userMediaRequests = 0;
  Completer<void>? gate;
  final Completer<void> requestStarted = Completer<void>();
  MediaStream? lastStream;

  @override
  Future<MediaStream> getUserMedia(
    Map<String, dynamic> mediaConstraints,
  ) async {
    userMediaRequests++;
    if (!requestStarted.isCompleted) requestStarted.complete();
    await gate?.future;
    return lastStream = await super.getUserMedia(mediaConstraints);
  }
}

final class _TrackingPeerConnection extends MockRTCPeerConnection {
  final List<RTCIceCandidate> appliedCandidates = <RTCIceCandidate>[];
  final Completer<void> restartStarted = Completer<void>();
  Completer<void>? restartGate;
  bool throwAfterRestartGate = false;

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    appliedCandidates.add(candidate);
    await super.addCandidate(candidate);
  }

  @override
  Future<void> restartIce() async {
    if (!restartStarted.isCompleted) restartStarted.complete();
    await restartGate?.future;
    if (throwAfterRestartGate) throw StateError('peer connection disposed');
    await super.restartIce();
  }
}

final class _FailingCandidatePeerConnection extends MockRTCPeerConnection {
  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    throw StateError('candidate application failed');
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
            duration == const Duration(seconds: 60) ||
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
