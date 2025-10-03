/// UnifiedPlan handler implementing WebRTC Unified Plan SDP semantics for media negotiation.
/// Handles transceiver management, codec negotiation, and SDP munging for WebRTC connections.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sdp_transform/sdp_transform.dart';
import 'package:mediasoup_client_flutter/src/ortc.dart';
import 'package:mediasoup_client_flutter/src/scalability_modes.dart';
import 'package:mediasoup_client_flutter/src/transport.dart';
import 'package:mediasoup_client_flutter/src/sctp_parameters.dart';
import 'package:mediasoup_client_flutter/src/rtp_parameters.dart';
import 'package:mediasoup_client_flutter/src/common/logger.dart';
import 'package:mediasoup_client_flutter/src/type_conversion.dart';
import 'package:mediasoup_client_flutter/src/handlers/handler_interface.dart';
import 'package:mediasoup_client_flutter/src/handlers/sdp/common_utils.dart';
import 'package:mediasoup_client_flutter/src/handlers/sdp/media_section.dart';
import 'package:mediasoup_client_flutter/src/handlers/sdp/remote_sdp.dart';

Logger _logger = Logger('UnifiedPlan');

dynamic _safeExtractValue(dynamic value) {
  if (value == null) {
    _logger.warn('_safeExtractValue() | Value is null');
    return null;
  }
  if (value is Map) {
    final extracted = value.values.firstOrNull ?? value;
    _logger.debug('_safeExtractValue() | Extracted from Map: $extracted');
    return extracted;
  }
  return value;
}

class UnifiedPlan extends HandlerInterface {
  late Direction _direction;
  late RemoteSdp _remoteSdp;
  late Map<RTCRtpMediaType, RtpParameters> _sendingRtpParametersByKind;
  late Map<RTCRtpMediaType, RtpParameters> _sendingRemoteRtpParametersByKind;
  DtlsRole? _forcedLocalDtlsRole;
  RTCPeerConnection? _pc;
  Map<String, RTCRtpTransceiver> _mapMidTransceiver = {};
  bool _hasDataChannelMediaSection = false;
  int _nextSendSctpStreamId = 0;
  bool _transportReady = false;

  UnifiedPlan() : super();

  Future<void> _setupTransport({
    required DtlsRole localDtlsRole,
    Map<String, dynamic>? localSdpMap,
  }) async {
    _logger.debug('_setupTransport() called with localDtlsRole: $localDtlsRole');
    if (localSdpMap == null) {
      final localDescription = await _pc!.getLocalDescription();
      localSdpMap = parse(localDescription!.sdp!);
      _logger.debug('_setupTransport() parsed local SDP: $localSdpMap');
    }

    DtlsParameters dtlsParameters = CommonUtils.extractDtlsParameters(localSdpMap);
    _logger.debug('_setupTransport() extracted DTLS parameters: ${dtlsParameters.toMap()}');

    dtlsParameters.role = localDtlsRole;
    _logger.debug('_setupTransport() set DTLS role: ${dtlsParameters.role}');

    _remoteSdp.updateDtlsRole(
      localDtlsRole == DtlsRole.client ? DtlsRole.server : DtlsRole.client,
    );
    _logger.debug('_setupTransport() updated remote DTLS role');

    safeEmit('@connect', {
      'dtlsParameters': dtlsParameters,
      'callback': () {
        _logger.debug('@connect callback invoked - transport connected');
      }, 
      'errback': (error) => _logger.error('connect error: $error'),
    });
    _logger.debug('_setupTransport() @connect emitted successfully');

    _transportReady = true;
    _logger.debug('_setupTransport() transportReady set to true');
  }

  void _assertSendDirection() {
    if (_direction != Direction.send) {
      throw ('method can just be called for handlers with "send" direction');
    }
  }

  void _assertRecvDirection() {
    if (_direction != Direction.recv) {
      throw ('method can just be called for handlers with "recv" direction');
    }
  }

  @override
  Future<void> close() async {
    _logger.debug('close()');
    if (_pc != null) {
      try {
        await _pc!.close();
      } catch (error) {}
    }
  }

  @override
  Future<RtpCapabilities> getNativeRtpCapabilities() async {
    _logger.debug('getNativeRtpCapabilities()');

    RTCPeerConnection pc = await createPeerConnection({
      'iceServers': [],
      'iceTransportPolicy': 'all',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
    }, {
      'optional': [{'DtlsSrtpKeyAgreement': true}],
    });

    try {
      RTCSessionDescription offer = await pc.createOffer({});
      final parsedOffer = parse(offer.sdp!);
      
      RtpCapabilities nativeRtpCapabilities = CommonUtils.extractRtpCapabilities(parsedOffer);
      _logger.debug('Extracted native RTP capabilities: codecs count = ${nativeRtpCapabilities.codecs.length}');

      // Fallback: If no codecs extracted (e.g., parsing error), add defaults
      if (nativeRtpCapabilities.codecs.isEmpty) {
        _logger.warn('No codecs in native capabilities - adding fallbacks');
        // Audio fallback: Opus
        nativeRtpCapabilities.codecs.add(RtpCodecCapability(
          kind: MediaKind.audio,
          mimeType: 'audio/opus',
          preferredPayloadType: 111,
          clockRate: 48000,
          channels: 2,
          parameters: {'minptime': 10, 'useinbandfec': 1},
          rtcpFeedback: [],
        ));
        // Video fallback: H264
        nativeRtpCapabilities.codecs.add(RtpCodecCapability(
          kind: MediaKind.video,
          mimeType: 'video/H264',
          preferredPayloadType: 96,
          clockRate: 90000,
          parameters: {'packetization-mode': 1, 'profile-level-id': '42e01f', 'level-asymmetry-allowed': 1},
          rtcpFeedback: [
            RtcpFeedback(type: 'nack'),
            RtcpFeedback(type: 'nack', parameter: 'pli'),
            RtcpFeedback(type: 'goog-remb'),
          ],
        ));
        // RTX for video
        nativeRtpCapabilities.codecs.add(RtpCodecCapability(
          kind: MediaKind.video,
          mimeType: 'video/rtx',
          preferredPayloadType: 97,
          clockRate: 90000,
          parameters: {'apt': 96},
          rtcpFeedback: [],
        ));
        _logger.debug('Added fallback codecs: now ${nativeRtpCapabilities.codecs.length} codecs');
      }

      await pc.close();
      
      return nativeRtpCapabilities;
    } catch (error) {
      await pc.close();
      _logger.error('Error getting native RTP capabilities: $error');
      throw error;
    }
  }

  @override
  SctpCapabilities getNativeSctpCapabilities() {
    return SctpCapabilities(
      numStreams: NumSctpStreams(
        mis: SCTP_NUM_STREAMS.MIS,
        os: SCTP_NUM_STREAMS.OS,
      ),
    );
  }

  @override
  Future<List<StatsReport>> getReceiverStats(String localId) async {
    _assertRecvDirection();
    RTCRtpTransceiver? transceiver = _mapMidTransceiver[localId];
    if (transceiver == null) throw ('associated RTCRtpTransceiver not found');
    return await transceiver.receiver.getStats();
  }

  @override
  Future<List<StatsReport>> getSenderStats(String localId) async {
    _assertSendDirection();
    RTCRtpTransceiver? transceiver = _mapMidTransceiver[localId];
    if (transceiver == null) throw ('associated RTCRtpTransceiver not found');
    return await transceiver.sender.getStats();
  }

  @override
  Future<List<StatsReport>> getTransportStats() async {
    return await _pc!.getStats();
  }

  @override
  String get name => 'UnifiedPlan';

  @override
  Future<HandlerReceiveResult> receive(HandlerReceiveOptions options) async {
    _assertRecvDirection();
    _logger.debug('receive() [trackId:${options.trackId}, kind:${TypeConversion.rtcMediaTypeToString(options.kind)}]');

    String localId = options.rtpParameters.mid ?? _mapMidTransceiver.length.toString();

    _remoteSdp.receive(
      mid: localId,
      kind: options.kind,
      offerRtpParameters: options.rtpParameters,
      streamId: options.rtpParameters.rtcp?.cname ?? '',
      trackId: options.trackId,
    );

    RTCSessionDescription offer = RTCSessionDescription(_remoteSdp.getSdp(), 'offer');
    _logger.debug('receive() | calling pc.setRemoteDescription() [offer:${offer.toMap()}]');

    await _pc!.setRemoteDescription(offer);

    RTCSessionDescription answer = await _pc!.createAnswer({});
    Map<String, dynamic> localSdpMap = parse(answer.sdp!);

    Map<String, dynamic>? answerMediaObject;
    for (var media in localSdpMap['media'] ?? []) {
      if (media['mid'] == localId) {
        answerMediaObject = media;
        break;
      }
    }

    if (answerMediaObject == null) {
      throw ('Media section not found for mid: $localId');
    }

    CommonUtils.applyCodecParameters(options.rtpParameters, answerMediaObject);

    answer = RTCSessionDescription(write(localSdpMap, null), 'answer');

    if (!_transportReady) {
      await _setupTransport(
        localDtlsRole: DtlsRole.client,
        localSdpMap: localSdpMap,
      );
    }

    _logger.debug('receive() | calling pc.setLocalDescription() [answer:${answer.toMap()}]');
    await _pc!.setLocalDescription(answer);

    final transceivers = await _pc!.getTransceivers();
    RTCRtpTransceiver? transceiver = transceivers.firstWhereOrNull(
      (t) => _safeExtractValue(t.mid) == localId,
    );

    if (transceiver == null) {
      throw ('new RTCRtpTransceiver not found');
    }

    _mapMidTransceiver[localId] = transceiver;

    final MediaStream? stream = _pc!.getRemoteStreams().firstWhereOrNull(
      (e) => e?.id == (options.rtpParameters.rtcp?.cname ?? '')
    );

    return HandlerReceiveResult(
      localId: localId,
      track: transceiver.receiver.track!,
      rtpReceiver: transceiver.receiver,
      stream: stream ?? await createLocalMediaStream('fallback-stream'),
    );
  }

  @override
  Future<HandlerReceiveDataChannelResult> receiveDataChannel(HandlerReceiveDataChannelOptions options) async {
    _assertRecvDirection();

    RTCDataChannelInit initOptions = RTCDataChannelInit();
    initOptions.negotiated = true;
    initOptions.id = options.sctpStreamParameters.streamId;
    initOptions.ordered = options.sctpStreamParameters.ordered ?? initOptions.ordered;
    initOptions.maxRetransmitTime = options.sctpStreamParameters.maxPacketLifeTime ?? initOptions.maxRetransmitTime;
    initOptions.maxRetransmits = options.sctpStreamParameters.maxRetransmits ?? initOptions.maxRetransmits;
    initOptions.protocol = options.protocol ?? initOptions.protocol;

    _logger.debug('receiveDataChannel() [options:${initOptions.toMap()}]');

    RTCDataChannel dataChannel = await _pc!.createDataChannel(options.label, initOptions);

    if (!_hasDataChannelMediaSection) {
      _remoteSdp.receiveSctpAssociation();

      RTCSessionDescription offer = RTCSessionDescription(_remoteSdp.getSdp(), 'offer');
      _logger.debug('receiveDataChannel() | calling pc.setRemoteDescription() [offer:${offer.toMap()}]');

      await _pc!.setRemoteDescription(offer);

      RTCSessionDescription answer = await _pc!.createAnswer({});

      if (!_transportReady) {
        Map<String, dynamic> localSdpMap = parse(answer.sdp!);
        await _setupTransport(
          localDtlsRole: _forcedLocalDtlsRole ?? DtlsRole.client,
          localSdpMap: localSdpMap,
        );
      }

      _logger.debug('receiveDataChannel() | calling pc.setLocalDescription() [answer:${answer.toMap()}]');
      await _pc!.setLocalDescription(answer);

      _hasDataChannelMediaSection = true;
    }

    return HandlerReceiveDataChannelResult(dataChannel: dataChannel);
  }

  @override
  Future<void> replaceTrack(ReplaceTrackOptions options) async {
    _assertSendDirection();
    _logger.debug('replaceTrack() [localId:${options.localId}]');

    RTCRtpTransceiver? transceiver = _mapMidTransceiver[options.localId];
    if (transceiver == null) throw ('associated RTCRtpTransceiver not found');
    await transceiver.sender.replaceTrack(options.track);
  }

  @override
  Future<void> restartIce(IceParameters iceParameters) async {
    _logger.debug('restartIce()');
    _remoteSdp.updateIceParameters(iceParameters);

    if (!_transportReady) return;

    if (_direction == Direction.send) {
      RTCSessionDescription offer = await _pc!.createOffer({'iceRestart': true});
      _logger.debug('restartIce() | calling pc.setLocalDescription() [offer:${offer.toMap()}]');
      await _pc!.setLocalDescription(offer);

      RTCSessionDescription answer = RTCSessionDescription(_remoteSdp.getSdp(), 'answer');
      _logger.debug('restartIce() | calling pc.setRemoteDescription() [answer:${answer.toMap()}]');
      await _pc!.setRemoteDescription(answer);
    } else {
      RTCSessionDescription offer = RTCSessionDescription(_remoteSdp.getSdp(), 'offer');
      _logger.debug('restartIce() | calling pc.setRemoteDescription() [offer:${offer.toMap()}]');
      await _pc!.setRemoteDescription(offer);

      RTCSessionDescription answer = await _pc!.createAnswer({});
      _logger.debug('restartIce() | calling pc.setLocalDescription() [answer:${answer.toMap()}]');
      await _pc!.setLocalDescription(answer);
    }
  }

  @override
  void run({required HandlerRunOptions options}) async {
    _logger.debug('run() called with direction: ${options.direction}');
    
    _direction = options.direction;
    _remoteSdp = RemoteSdp(
      iceParameters: options.iceParameters,
      iceCandidates: options.iceCandidates,
      dtlsParameters: options.dtlsParameters,
      sctpParameters: options.sctpParameters,
    );
    _logger.debug('run() initialized RemoteSdp');

    _sendingRtpParametersByKind = {
      RTCRtpMediaType.RTCRtpMediaTypeAudio: Ortc.getSendingRtpParameters(
        MediaKind.audio, 
        options.extendedRtpCapabilities!,
      ),
      RTCRtpMediaType.RTCRtpMediaTypeVideo: Ortc.getSendingRtpParameters(
        MediaKind.video, 
        options.extendedRtpCapabilities!,
      ),
    };

    // CRITICAL: Validate codecs were created
    _logger.debug('Sending RTP parameters map created with keys: ${_sendingRtpParametersByKind.keys.toList()}');
    _sendingRtpParametersByKind.forEach((kind, params) {
      _logger.debug('Kind $kind has ${params.codecs.length} codecs: ${params.codecs.map((c) => c.mimeType).join(", ")}');
      if (params.codecs.isEmpty) {
        _logger.error('FATAL: No codecs for kind $kind - extended capabilities may be incomplete');
      }
    });

    _sendingRemoteRtpParametersByKind = {
      RTCRtpMediaType.RTCRtpMediaTypeAudio: Ortc.getSendingRemoteRtpParameters(
        MediaKind.audio, 
        options.extendedRtpCapabilities!,
      ),
      RTCRtpMediaType.RTCRtpMediaTypeVideo: Ortc.getSendingRemoteRtpParameters(
        MediaKind.video, 
        options.extendedRtpCapabilities!,
      ),
    };
    _logger.debug('run() set _sendingRemoteRtpParametersByKind');

    if (options.dtlsParameters.role != DtlsRole.auto) {
      _forcedLocalDtlsRole = options.dtlsParameters.role == DtlsRole.server
          ? DtlsRole.client
          : DtlsRole.server;
      _logger.debug('run() set _forcedLocalDtlsRole: $_forcedLocalDtlsRole');
    }

    final constraints = options.proprietaryConstraints.isEmpty
        ? <String, dynamic>{
            'mandatory': {},
            'optional': [{'DtlsSrtpKeyAgreement': true}],
          }
        : options.proprietaryConstraints;
    _logger.debug('run() using constraints: $constraints');

    _pc = await createPeerConnection(
      {
        'iceServers': options.iceServers.map((i) => i.toMap()).toList(),
        'iceTransportPolicy': options.iceTransportPolicy?.value ?? 'all',
        'bundlePolicy': 'max-bundle',
        'rtcpMuxPolicy': 'require',
        'sdpSemantics': 'unified-plan',
        ...options.additionalSettings,
      },
      constraints,
    );
    _logger.debug('run() created RTCPeerConnection');

    _pc!.onIceConnectionState = (RTCIceConnectionState state) {
      final stateStr = state.toString().split('.').last;
      _logger.debug('run() ICE connection state changed: $stateStr');
      emit('@connectionstatechange', {'state': stateStr.toLowerCase()});
    };
  }

  Future<DtlsParameters> getDtlsParameters() async {
    _logger.debug('getDtlsParameters()');
    final offer = await _pc!.createOffer({});
    final localSdpObject = parse(offer.sdp ?? '');
    final dtlsParameters = CommonUtils.extractDtlsParameters(localSdpObject);
    dtlsParameters.role = DtlsRole.auto;
    return dtlsParameters;
  }

  @override
  Future<HandlerSendResult> send(HandlerSendOptions options) async {
    _assertSendDirection();
    
    _logger.debug('send() [kind:${options.track.kind}, track.id:${options.track.id}]');

    if (options.track == null) {
      _logger.error('send() called with null track');
      throw Exception('Track cannot be null');
    }

    final track = options.track;
    final encodings = options.encodings;
    final codecOptions = options.codecOptions;
    final codec = options.codec;
    final stream = options.stream;

    final rtcMediaType = track.kind == 'audio' 
        ? RTCRtpMediaType.RTCRtpMediaTypeAudio 
        : RTCRtpMediaType.RTCRtpMediaTypeVideo;
    
    final sourceParams = _sendingRtpParametersByKind[rtcMediaType];
    if (sourceParams == null) {
      _logger.error('No source parameters for: $rtcMediaType');
      throw Exception('No RTP parameters available for $rtcMediaType');
    }
    
    var sendingRtpParameters = RtpParameters(
      mid: sourceParams.mid,
      codecs: sourceParams.codecs.map((c) => RtpCodecParameters(
        mimeType: c.mimeType,
        payloadType: c.payloadType,
        clockRate: c.clockRate,
        channels: c.channels,
        parameters: Map<String, dynamic>.from(c.parameters),
        rtcpFeedback: c.rtcpFeedback.map((fb) => RtcpFeedback(
          type: fb.type,
          parameter: fb.parameter,
        )).toList(),
      )).toList(),
      headerExtensions: sourceParams.headerExtensions.map((ext) => RtpHeaderExtensionParameters(
        uri: ext.uri,
        id: ext.id!,
        encrypt: ext.encrypt ?? false,
        parameters: Map<String, dynamic>.from(ext.parameters),
      )).toList(),
      encodings: sourceParams.encodings?.map((enc) => RtpEncodingParameters(
        rid: enc.rid,
        ssrc: enc.ssrc,
        active: enc.active,
        maxBitrate: enc.maxBitrate,
        scaleResolutionDownBy: enc.scaleResolutionDownBy,
        maxFramerate: enc.maxFramerate,
        dtx: enc.dtx,
        scalabilityMode: enc.scalabilityMode,
      )).toList() ?? [],
      rtcp: RtcpParameters(
        cname: sourceParams.rtcp?.cname ?? 'webrtc-${(track.id ?? 'unknown').substring(0, math.min(8, (track.id ?? 'unknown').length))}',
        reducedSize: sourceParams.rtcp?.reducedSize ?? true,
        mux: sourceParams.rtcp?.mux ?? true,
      ),
    );
    
    _logger.debug('Codecs: ${sendingRtpParameters.codecs.length}, RTCP cname: ${sendingRtpParameters.rtcp?.cname}');

    if (codec != null) {
      sendingRtpParameters.codecs = [
        RtpCodecParameters(
          mimeType: codec.mimeType,
          payloadType: codec.preferredPayloadType ?? 96,
          clockRate: codec.clockRate,
          channels: codec.channels,
          parameters: Map<String, dynamic>.from(codec.parameters),
          rtcpFeedback: codec.rtcpFeedback.map((fb) => RtcpFeedback(
            type: fb.type,
            parameter: fb.parameter,
          )).toList(),
        )
      ];
    }

    List<RtpEncodingParameters> sanitizedEncodings;
    
    if (encodings == null || encodings.isEmpty) {
      sanitizedEncodings = [
        RtpEncodingParameters(
          ssrc: (math.Random().nextDouble() * 4294967295).floor(),
          active: true,
          maxBitrate: rtcMediaType == RTCRtpMediaType.RTCRtpMediaTypeVideo ? 2000000 : 128000,
        )
      ];
    } else {
      sanitizedEncodings = encodings.asMap().entries.map((entry) {
        final e = entry.value;
        final idx = entry.key;
        return RtpEncodingParameters(
          rid: e.rid ?? (encodings.length > 1 ? 'r$idx' : null),
          ssrc: e.ssrc ?? (math.Random().nextDouble() * 4294967295).floor(),
          active: e.active ?? true,
          maxBitrate: e.maxBitrate,
          scaleResolutionDownBy: e.scaleResolutionDownBy,
          maxFramerate: e.maxFramerate,
        );
      }).toList();
    }

    sendingRtpParameters.encodings = sanitizedEncodings;
    
    if (sendingRtpParameters.encodings!.length > 1) {
      for (int idx = 0; idx < sendingRtpParameters.encodings!.length; idx++) {
        if (sendingRtpParameters.encodings![idx].rid == null) {
          sendingRtpParameters.encodings![idx] = RtpEncodingParameters(
            rid: 'r$idx',
            ssrc: sendingRtpParameters.encodings![idx].ssrc,
            active: sendingRtpParameters.encodings![idx].active,
            maxBitrate: sendingRtpParameters.encodings![idx].maxBitrate,
            scaleResolutionDownBy: sendingRtpParameters.encodings![idx].scaleResolutionDownBy,
            maxFramerate: sendingRtpParameters.encodings![idx].maxFramerate,
          );
        }
      }
    }

    List<RTCRtpEncoding> rtcEncodings = sendingRtpParameters.encodings!.map((encoding) {
      if (encoding.ssrc == null) {
        throw Exception('Encoding SSRC generation failed');
      }
      return RTCRtpEncoding(
        rid: encoding.rid,
        active: encoding.active ?? true,
        maxBitrate: encoding.maxBitrate,
        maxFramerate: encoding.maxFramerate?.round(),
        scaleResolutionDownBy: encoding.scaleResolutionDownBy,
        ssrc: encoding.ssrc,
      );
    }).toList();

    _logger.debug('Creating transceiver with ${rtcEncodings.length} encodings');

    if (_pc == null) {
      throw Exception('Peer connection not initialized');
    }

    RTCRtpTransceiver? transceiver;
    try {
      transceiver = await _pc!.addTransceiver(
        track: track,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendOnly,
          streams: stream != null ? [stream] : [],
        ),
      );
      
      if (transceiver == null) {
        throw Exception('addTransceiver returned null');
      }
      
      _logger.debug('Transceiver created successfully');
    } catch (error, stackTrace) {
      _logger.error('Failed to add transceiver: $error');
      _logger.error('Stack: $stackTrace');
      rethrow;
    }

    await Future.delayed(const Duration(milliseconds: 200));

    final offer = await _pc!.createOffer({});
    var localSdpObject = parse(offer.sdp ?? '');

    Map<String, dynamic>? offerMediaObject;
    for (var media in localSdpObject['media'] ?? []) {
      if (media['type'] == track.kind) {
        offerMediaObject = media;
        break;
      }
    }

    if (offerMediaObject == null) {
      throw Exception('No media section found for ${track.kind}');
    }

    if (codec != null) {
      final codecName = codec.mimeType.split('/')[1].toLowerCase();
      offerMediaObject['rtp'] = [
        ...offerMediaObject['rtp'].where((r) => r['codec'].toLowerCase() == codecName),
        ...offerMediaObject['rtp'].where((r) => r['codec'].toLowerCase() != codecName),
      ];
      offerMediaObject['payloads'] = offerMediaObject['rtp'].map((r) => r['payload']).join(' ');
    }

    final modifiedSdp = write(localSdpObject, null);
    await _pc!.setLocalDescription(RTCSessionDescription(modifiedSdp, 'offer'));
    
    _logger.debug('Local description set, waiting for mid assignment...');

    String? assignedMid;
    for (int attempt = 0; attempt < 50; attempt++) {
      await Future.delayed(const Duration(milliseconds: 100));
      
      try {
        final currentMid = transceiver.mid;
        
        _logger.debug('Attempt ${attempt + 1}: transceiver.mid = $currentMid (type: ${currentMid.runtimeType})');
        
        if (currentMid != null && currentMid.isNotEmpty && currentMid != 'null') {
          assignedMid = currentMid;
          _logger.debug('✅ MID assigned: $assignedMid (attempt ${attempt + 1})');
          break;
        }
      } catch (e) {
        _logger.warn('❌ Error reading mid (attempt ${attempt + 1}): $e');
      }
    }

    if (assignedMid == null || assignedMid.isEmpty || assignedMid == 'null') {
      _logger.warn('⚠️ MID not assigned by transceiver after 50 attempts, extracting from SDP');
      
      final currentLocal = await _pc!.getLocalDescription();
      if (currentLocal != null) {
        final parsedSdp = parse(currentLocal.sdp!);
        
        for (var media in parsedSdp['media'] ?? []) {
          if (media['type'] == track.kind && media['mid'] != null) {
            assignedMid = media['mid'].toString();
            _logger.debug('✅ Extracted MID from SDP: $assignedMid');
            break;
          }
        }
      }
      
      if (assignedMid == null || assignedMid.isEmpty) {
        throw Exception('❌ FATAL: Failed to get MID from transceiver or SDP');
      }
    }

    sendingRtpParameters.codecs = Ortc.reduceCodecs(sendingRtpParameters.codecs, codec);
    
    // ⚡ CRITICAL FIX: Safe header extension parsing
    _logger.debug('Parsing header extensions from SDP...');
    try {
      final extList = offerMediaObject['ext'];
      _logger.debug('Raw ext list: $extList (type: ${extList.runtimeType})');
      
      if (extList != null && extList is List) {
        final parsedExtensions = <RtpHeaderExtensionParameters>[];
        
        for (int i = 0; i < extList.length; i++) {
          final e = extList[i];
          _logger.debug('Parsing ext[$i]: $e (type: ${e.runtimeType})');
          
          if (e == null || e is! Map) {
            _logger.warn('Skipping invalid ext[$i]: not a Map');
            continue;
          }
          
          final uri = e['uri'];
          final id = e['value']; // Note: SDP parser uses 'value', not 'id'
          
          _logger.debug('ext[$i]: uri=$uri (${uri.runtimeType}), value=$id (${id.runtimeType})');
          
          if (uri == null || uri is! String) {
            _logger.warn('Skipping ext[$i]: uri is null or not String');
            continue;
          }
          
          if (id == null) {
            _logger.warn('Skipping ext[$i]: id/value is null');
            continue;
          }
          
          int? parsedId;
          if (id is int) {
            parsedId = id;
          } else if (id is String) {
            parsedId = int.tryParse(id);
          } else {
            try {
              parsedId = int.parse(id.toString());
            } catch (e) {
              _logger.warn('Skipping ext[$i]: cannot parse id "$id" to int');
              continue;
            }
          }
          
          if (parsedId == null) {
            _logger.warn('Skipping ext[$i]: parsed id is null');
            continue;
          }
          
          parsedExtensions.add(RtpHeaderExtensionParameters(
            uri: uri,
            id: parsedId,
            encrypt: false,
          ));
          
          _logger.debug('✅ Added header extension: uri=$uri, id=$parsedId');
        }
        
        sendingRtpParameters.headerExtensions = parsedExtensions;
        _logger.debug('Parsed ${parsedExtensions.length} header extensions successfully');
      } else {
        _logger.warn('No header extensions found in offer media object (ext is null or not List)');
        sendingRtpParameters.headerExtensions = [];
      }
    } catch (extError, stackTrace) {
      _logger.error('❌ Error parsing header extensions: $extError');
      _logger.error('Stack trace: $stackTrace');
      _logger.error('offerMediaObject[ext]: ${offerMediaObject['ext']}');
      sendingRtpParameters.headerExtensions = [];
    }
    
    sendingRtpParameters.mid = assignedMid;

    if (!_transportReady) {
      await _setupTransport(
        localDtlsRole: _forcedLocalDtlsRole ?? DtlsRole.client,
        localSdpMap: localSdpObject,
      );
    }

    _mapMidTransceiver[assignedMid] = transceiver;

    _logger.debug('send() completed: mid=$assignedMid, codecs=${sendingRtpParameters.codecs.length}, extensions=${sendingRtpParameters.headerExtensions.length}');

    return HandlerSendResult(
      localId: assignedMid,
      rtpParameters: sendingRtpParameters,
      rtpSender: transceiver.sender,
    );
  }

  @override
  Future<HandlerSendDataChannelResult> sendDataChannel(SendDataChannelArguments options) async {
    _assertSendDirection();

    RTCDataChannelInit initOptions = RTCDataChannelInit();
    initOptions.negotiated = true;
    initOptions.id = _nextSendSctpStreamId;
    initOptions.ordered = options.ordered ?? initOptions.ordered;
    initOptions.maxRetransmitTime = options.maxPacketLifeTime ?? initOptions.maxRetransmitTime;
    initOptions.maxRetransmits = options.maxRetransmits ?? initOptions.maxRetransmits;
    initOptions.protocol = options.protocol ?? initOptions.protocol;

    _logger.debug('sendDataChannel() [options:${initOptions.toMap()}]');

    RTCDataChannel dataChannel = await _pc!.createDataChannel(options.label!, initOptions);
    _nextSendSctpStreamId = ++_nextSendSctpStreamId % SCTP_NUM_STREAMS.MIS;

    if (!_hasDataChannelMediaSection) {
      RTCSessionDescription offer = await _pc!.createOffer({});
      Map<String, dynamic> localSdpMap = parse(offer.sdp!);
      
      Map<String, dynamic>? offerMediaObject;
      for (var media in localSdpMap['media'] ?? []) {
        if (media['type'] == 'application') {
          offerMediaObject = media;
          break;
        }
      }

      if (!_transportReady) {
        await _setupTransport(
          localDtlsRole: _forcedLocalDtlsRole ?? DtlsRole.client,
          localSdpMap: localSdpMap,
        );
      }

      _logger.debug('sendDataChannel() | calling pc.setLocalDescription() [offer:${offer.toMap()}]');
      await _pc!.setLocalDescription(offer);

      if (offerMediaObject != null) {
        _remoteSdp.sendSctpAssociation(offerMediaObject);
      }

      RTCSessionDescription answer = RTCSessionDescription(_remoteSdp.getSdp(), 'answer');
      _logger.debug('sendDataChannel() | calling pc.setRemoteDescription() [answer:${answer.toMap()}]');
      await _pc!.setRemoteDescription(answer);

      _hasDataChannelMediaSection = true;
    }

    SctpStreamParameters sctpStreamParameters = SctpStreamParameters(
      streamId: initOptions.id!,
      ordered: initOptions.ordered,
      maxPacketLifeTime: initOptions.maxRetransmitTime,
      maxRetransmits: initOptions.maxRetransmits,
    );

    return HandlerSendDataChannelResult(
      dataChannel: dataChannel,
      sctpStreamParameters: sctpStreamParameters,
    );
  }

  @override
  Future<void> setMaxSpatialLayer(SetMaxSpatialLayerOptions options) async {
    _assertSendDirection();
    _logger.debug('setMaxSpatialLayer() [localId:${options.localId}, spatialLayer:${options.spatialLayer}]');

    RTCRtpTransceiver? transceiver = _mapMidTransceiver[options.localId];
    if (transceiver == null) throw ('associated RTCRtpTransceiver not found');

    RTCRtpParameters parameters = transceiver.sender.parameters;

    int idx = 0;
    for (var encoding in parameters.encodings!) {
      encoding.active = (idx <= options.spatialLayer);
      idx++;
    }

    await transceiver.sender.setParameters(parameters);
  }

  @override
  Future<void> setRtpEncodingParameters(SetRtpEncodingParametersOptions options) async {
    _assertSendDirection();
    _logger.debug('setRtpEncodingParameters() [localId:${options.localId}, params:${options.params}]');

    RTCRtpTransceiver? transceiver = _mapMidTransceiver[options.localId];
    if (transceiver == null) throw ('associated RTCRtpTransceiver not found');

    RTCRtpParameters parameters = transceiver.sender.parameters;

    int idx = 0;
    for (var encoding in parameters.encodings!) {
      parameters.encodings![idx] = RTCRtpEncoding(
        active: options.params.active ?? encoding.active,
        maxBitrate: options.params.maxBitrate ?? encoding.maxBitrate,
        maxFramerate: options.params.maxFramerate != null 
            ? options.params.maxFramerate!.round()
            : encoding.maxFramerate?.round(),
        minBitrate: options.params.minBitrate ?? encoding.minBitrate,
        numTemporalLayers: options.params.numTemporalLayers ?? encoding.numTemporalLayers,
        rid: options.params.rid ?? encoding.rid,
        scaleResolutionDownBy: options.params.scaleResolutionDownBy ?? encoding.scaleResolutionDownBy,
        ssrc: options.params.ssrc ?? encoding.ssrc,
      );
      idx++;
    }

    await transceiver.sender.setParameters(parameters);
  }

  @override
  Future<void> stopReceiving(String localId) async {
    _assertRecvDirection();
    _logger.debug('stopReceiving() [localId:$localId]');

    RTCRtpTransceiver? transceiver = _mapMidTransceiver[localId];
    if (transceiver == null) throw ('associated RTCRtpTransceiver not found');

    await transceiver.setDirection(TransceiverDirection.Inactive);
    
    String midString = _safeExtractValue(transceiver.mid)?.toString() ?? '0';
    
    _remoteSdp.closeMediaSection(midString);

    RTCSessionDescription offer = RTCSessionDescription(_remoteSdp.getSdp(), 'offer');
    _logger.debug('stopReceiving() | calling pc.setRemoteDescription() [offer:${offer.toMap()}]');
    await _pc!.setRemoteDescription(offer);

    RTCSessionDescription answer = await _pc!.createAnswer({});
    _logger.debug('stopReceiving() | calling pc.setLocalDescription() [answer:${answer.toMap()}]');
    await _pc!.setLocalDescription(answer);
    
    _mapMidTransceiver.remove(localId);
  }

  @override
  Future<void> stopSending(String localId) async {
    _assertSendDirection();
    _logger.debug('stopSending() [localId:$localId]');

    // ✅ FIX: Add null check for localId
    if (localId == null || localId.isEmpty) {
      _logger.error('stopSending() called with null or empty localId');
      throw Exception('localId cannot be null or empty');
    }

    RTCRtpTransceiver? transceiver = _mapMidTransceiver[localId];
    if (transceiver == null) {
      _logger.error('stopSending() | transceiver not found for localId: $localId');
      throw Exception('associated RTCRtpTransceiver not found');
    }

    // ✅ FIX: Safe mid extraction
    String? midValue = _safeExtractValue(transceiver.mid)?.toString();
    
    if (midValue == null || midValue.isEmpty || midValue == 'null') {
      _logger.warn('stopSending() | mid is null, using localId as fallback: $localId');
      midValue = localId;
    }
    
    _logger.debug('stopSending() | Using mid: $midValue for transceiver');

    // Remove track
    await _pc!.removeTrack(transceiver.sender);
    
    // ✅ FIX: Close media section with validated mid
    try {
      _remoteSdp.closeMediaSection(midValue);
      _logger.debug('stopSending() | Media section closed for mid: $midValue');
    } catch (error) {
      _logger.error('stopSending() | Failed to close media section: $error');
      // Continue anyway - don't let SDP error block cleanup
    }

    // Generate new offer
    RTCSessionDescription offer = await _pc!.createOffer({});
    _logger.debug('stopSending() | calling pc.setLocalDescription()');
    await _pc!.setLocalDescription(offer);

    // Generate answer
    RTCSessionDescription answer = RTCSessionDescription(_remoteSdp.getSdp(), 'answer');
    _logger.debug('stopSending() | calling pc.setRemoteDescription()');
    
    try {
      await _pc!.setRemoteDescription(answer);
      _logger.debug('stopSending() | Remote description set successfully');
    } catch (error) {
      _logger.error('stopSending() | setRemoteDescription failed: $error');
      _logger.error('stopSending() | Answer SDP: ${answer.sdp}');
      throw Exception('Failed to set remote description: $error');
    }
    
    _mapMidTransceiver.remove(localId);
    _logger.debug('stopSending() | Completed for localId: $localId');
  }
  @override
  Future<void> updateIceServers(List<RTCIceServer> iceServers) async {
    _logger.debug('updateIceServers()');
    
    try {
      final config = <String, dynamic>{
        'iceServers': iceServers.map((server) => server.toMap()).toList(),
        'iceTransportPolicy': 'all',
        'bundlePolicy': 'max-bundle',
        'rtcpMuxPolicy': 'require',
        'sdpSemantics': 'unified-plan',
      };
      
      await _pc!.setConfiguration(config);
    } catch (error) {
      _logger.error('updateIceServers() failed: $error');
      _logger.warn('Ice servers update might not be fully supported: $error');
    }
  }
}

extension FirstWhereOrNullExtension<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (E element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}