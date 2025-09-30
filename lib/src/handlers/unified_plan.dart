import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:js_util' as js_util;
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
import 'package:mediasoup_client_flutter/src/handlers/sdp/unified_plan_utils.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

// Helper function to safely extract values that might be wrapped in IdentityMap
// Helper function to safely extract values
dynamic _safeExtractValue(dynamic value) {
  if (value == null) return null;
  if (value is Map) return value.values.firstOrNull ?? value;
  return value;
}

Logger _logger = Logger('Unified plan handler');

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
  ExtendedRtpCapabilities? _extendedRtpCapabilities;

  UnifiedPlan() : super();

  Future<void> _setupTransport({
    required DtlsRole localDtlsRole,
    Map<String, dynamic>? localSdpMap,
  }) async {
    if (localSdpMap == null) {
      final localDescription = await _pc!.getLocalDescription();
      localSdpMap = parse(localDescription!.sdp!);
    }

    // Get our local DTLS parameters.
    DtlsParameters dtlsParameters = CommonUtils.extractDtlsParameters(localSdpMap);

    // Set our DTLS role.
    dtlsParameters.role = localDtlsRole;

    // Update the remote DTLC role in the SDP.
    _remoteSdp.updateDtlsRole(
      localDtlsRole == DtlsRole.client ? DtlsRole.server : DtlsRole.client,
    );

    // Need to tell the remote transport about our parameters.
    await safeEmitAsFuture('@connect', {
      'dtlsParameters': dtlsParameters,
    });

    _transportReady = true;
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
      await pc.close();
      
      return nativeRtpCapabilities;
    } catch (error) {
      await pc.close();
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
  String get name => 'Unified plan handler';

  @override
  Future<HandlerReceiveResult> receive(HandlerReceiveOptions options) async {
    _assertRecvDirection();
    _logger.debug('receive() [trackId:${options.trackId}, kind:${TypeConversion.rtcMediaTypeToString(options.kind)}]');

    String localId = options.rtpParameters.mid ?? _mapMidTransceiver.length.toString();

    _remoteSdp.receive(
      mid: localId,
      kind: TypeConversion.rtcMediaTypeToString(options.kind),
      offerRtpParameters: options.rtpParameters,
      streamId: options.rtpParameters.rtcp?.cname ?? '',
      trackId: options.trackId,
    );

    RTCSessionDescription offer = RTCSessionDescription(_remoteSdp.getSdp(), 'offer');
    _logger.debug('receive() | calling pc.setRemoteDescription() [offer:${offer.toMap()}]');

    await _pc!.setRemoteDescription(offer);

    RTCSessionDescription answer = await _pc!.createAnswer({});
    Map<String, dynamic> localSdpMap = parse(answer.sdp!);

    // Find the media section by MID
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

    // Apply codec parameters
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
    _logger.debug('run()');
    _direction = options.direction;
    _extendedRtpCapabilities = options.extendedRtpCapabilities;

    _remoteSdp = RemoteSdp(
      iceParameters: options.iceParameters,
      iceCandidates: options.iceCandidates,
      dtlsParameters: options.dtlsParameters,
      sctpParameters: options.sctpParameters,
    );

    // Use TypeConversion consistently
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

    if (options.dtlsParameters.role != DtlsRole.auto) {
      _forcedLocalDtlsRole = options.dtlsParameters.role == DtlsRole.server
          ? DtlsRole.client
          : DtlsRole.server;
    }

    final constraints = options.proprietaryConstraints.isEmpty
        ? <String, dynamic>{
            'mandatory': {},
            'optional': [{'DtlsSrtpKeyAgreement': true}],
          }
        : options.proprietaryConstraints;

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

    _pc!.onIceConnectionState = (RTCIceConnectionState state) {
      final stateStr = state.toString().split('.').last;
      emit('@connectionstatechange', {'state': stateStr.toLowerCase()});
    };
  }

    Future<DtlsParameters> getDtlsParameters() async {
      _logger.debug('getDtlsParameters()');
      final offer = await _pc!.createOffer({}); // Use Map for options
      final localSdpObject = parse(offer.sdp ?? '');
      final dtlsParameters = CommonUtils.extractDtlsParameters(localSdpObject);
      dtlsParameters.role = DtlsRole.auto;
      return dtlsParameters;
    }

  @override
  Future<HandlerSendResult> send(HandlerSendOptions options) async {
    _assertSendDirection();
    _logger.debug('send() [kind:${options.track.kind}, track.id:${options.track.id}, source:${options.source ?? 'unknown'}]');

    final track = options.track;
    final encodings = options.encodings;
    final codecOptions = options.codecOptions;
    final codec = options.codec;
    final stream = options.stream;

    if (encodings != null && encodings.length > 1) {
      for (int idx = 0; idx < encodings.length; idx++) {
        encodings[idx].rid = 'r$idx';
      }
    }

    List<RTCRtpEncoding>? rtcEncodings;
    if (encodings != null) {
      rtcEncodings = encodings.map((e) => RTCRtpEncoding(
            rid: e.rid,
            active: e.active ?? true,
            maxBitrate: e.maxBitrate,
            maxFramerate: e.maxFramerate?.round(),
            scaleResolutionDownBy: e.scaleResolutionDownBy,
          )).toList();
    }

    final transceiver = await _pc!.addTransceiver(
      track: track,
      init: RTCRtpTransceiverInit(
        direction: TransceiverDirection.SendOnly,
        streams: [stream],
        sendEncodings: rtcEncodings,
      ),
    );

    final offer = await _pc!.createOffer({});
    var localSdpObject = parse(offer.sdp ?? '');

    Map<String, dynamic>? offerMediaObject = localSdpObject['media'].firstWhere(
      (m) => m['mid'] == transceiver.mid && m['type'] == track.kind,
      orElse: () => null,
    );

    if (offerMediaObject == null) {
      throw Exception('No media section found for MID: ${transceiver.mid} and kind: ${track.kind}');
    }

    if (encodings != null) {
      offerMediaObject['rtp'] = [];
      offerMediaObject['fmtp'] = [];
      for (var encoding in encodings) {
        int pt = 96 + encodings.indexOf(encoding);
        offerMediaObject['rtp'].add({
          'payload': pt,
          'codec': codec?.mimeType.split('/')[1] ?? 'VP8',
          'rate': codec?.clockRate ?? 90000,
        });
        if (codecOptions != null) {
          final params = codecOptions.toMap();
          if (params.isNotEmpty) {
            offerMediaObject['fmtp'].add({
              'payload': pt,
              'config': params.entries.map((e) => '${e.key}=${e.value}').join(';'),
            });
          }
        }
      }
      offerMediaObject['payloads'] = offerMediaObject['rtp'].map((r) => r['payload']).join(' ');
    }

    if (codec != null) {
      offerMediaObject['rtp'] = [
        ...offerMediaObject['rtp'].where((r) => r['codec'].toLowerCase() == codec.mimeType.split('/')[1].toLowerCase()),
        ...offerMediaObject['rtp'].where((r) => r['codec'].toLowerCase() != codec.mimeType.split('/')[1].toLowerCase()),
      ];
      offerMediaObject['payloads'] = offerMediaObject['rtp'].map((r) => r['payload']).join(' ');
    }

    final modifiedSdp = write(localSdpObject, null);
    await _pc!.setLocalDescription(RTCSessionDescription(modifiedSdp, 'offer'));

    final sendingRtpParameters = Ortc.getSendingRtpParameters(
      TypeConversion.rtcToMediaKind(transceiver.sender.track!.kind == 'audio'
          ? RTCRtpMediaType.RTCRtpMediaTypeAudio
          : RTCRtpMediaType.RTCRtpMediaTypeVideo),
      _extendedRtpCapabilities!,
    );

    // Handle extracted codecs and assign payloadType
    final extractedCodecs = CommonUtils.extractRtpCapabilities(offerMediaObject).codecs;
    final codecParameters = extractedCodecs.asMap().entries.map((entry) {
      final c = entry.value;
      return RtpCodecParameters(
        mimeType: c.mimeType,
        clockRate: c.clockRate,
        payloadType: 96 + entry.key, // Assign dynamic payload type
        channels: c.channels,
        parameters: c.parameters,
        rtcpFeedback: c.rtcpFeedback,
      );
    }).toList();

    sendingRtpParameters.codecs = Ortc.reduceCodecs(codecParameters, codec);
    sendingRtpParameters.encodings = encodings ?? [RtpEncodingParameters(scaleResolutionDownBy: 1.0)];
    
    // Debug log the extensions before processing
    _logger.debug('offerMediaObject[ext]: ${offerMediaObject['ext']}');
    
    try {
      sendingRtpParameters.headerExtensions = (offerMediaObject['ext'] as List<dynamic>?)?.map((e) {
        final uri = e['uri']?.toString();
        final id = e['id'] is int ? e['id'] : int.tryParse(e['id']?.toString() ?? '0') ?? 0;
        
        if (uri == null) {
          _logger.warn('Header extension entry is missing URI: $e');
          return null;
        }
        
        return RtpHeaderExtensionParameters(
          uri: uri,
          id: id,
          encrypt: e['encrypt'] == true,
        );
      }).whereType<RtpHeaderExtensionParameters>().toList() ?? [];
      
      _logger.debug('Processed ${sendingRtpParameters.headerExtensions.length} header extensions');
    } catch (error) {
      _logger.error('Error processing header extensions: $error');
      sendingRtpParameters.headerExtensions = [];
    }
    
    sendingRtpParameters.mid = transceiver.mid;

    return HandlerSendResult(
      localId: transceiver.mid ?? '',
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
      
      // Find application media section
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

      // Handle SCTP association in remote SDP
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
            ? options.params.maxFramerate!.round() // Convert to int
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
    
    dynamic midValue = transceiver.mid;
    String midString = _safeExtractValue(midValue)?.toString() ?? '0';
    
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

    RTCRtpTransceiver? transceiver = _mapMidTransceiver[localId];
    if (transceiver == null) throw ('associated RTCRtpTransceiver not found');

    await _pc!.removeTrack(transceiver.sender);
    
    dynamic midValue = transceiver.mid;
    String midString = _safeExtractValue(midValue)?.toString() ?? '0';
    
    _remoteSdp.closeMediaSection(midString);

    RTCSessionDescription offer = await _pc!.createOffer({});
    _logger.debug('stopSending() | calling pc.setLocalDescription() [offer:${offer.toMap()}]');
    await _pc!.setLocalDescription(offer);

    RTCSessionDescription answer = RTCSessionDescription(_remoteSdp.getSdp(), 'answer');
    _logger.debug('stopSending() | calling pc.setRemoteDescription() [answer:${answer.toMap()}]');
    await _pc!.setRemoteDescription(answer);
    
    _mapMidTransceiver.remove(localId);
  }

  @override
  Future<void> updateIceServers(List<RTCIceServer> iceServers) async {
    _logger.debug('updateIceServers()');
    
    try {
      // For flutter_webrtc, we need to use a different approach
      // since getConfiguration() might not be available directly
      
      // Create a configuration map instead of using RTCConfiguration class
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
      // In some WebRTC implementations, updating ice servers might not be supported
      // after peer connection creation. This is not a critical error.
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