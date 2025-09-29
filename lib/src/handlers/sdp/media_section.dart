import 'dart:math';
import 'dart:convert';
import 'package:sdp_transform/sdp_transform.dart';
import 'package:mediasoup_client_flutter/src/rtp_parameters.dart';
import 'package:mediasoup_client_flutter/src/sctp_parameters.dart';
import 'package:mediasoup_client_flutter/src/transport.dart';

/// Base class for media sections in SDP
abstract class MediaSection {
  /// The media object (m= line and its attributes) as Map from sdp-transform
  final Map<String, dynamic> _mediaObject;
  
  /// The MID for this media section
  final String mid;
  
  /// The media kind (audio, video, application)
  final String kind;
  
  /// The CNAME for RTCP
  final String? cname;
  
  /// Whether RTX is enabled
  final bool enableRtx;
  
  /// Whether SRTP is enabled
  final bool enableSrtp;
  
  /// Whether SCTP is enabled
  final bool enableSctp;
  
  /// Whether UDP is enabled
  final bool enableUdp;
  
  /// Whether TCP is enabled
  final bool enableTcp;
  
  /// Whether RTCP muxing is enabled
  final bool enableRtcpMux;
  
  /// Whether this is a data channel
  final bool isDataChannel;
  
  /// The media object (m= line and its attributes)
  Map<String, dynamic> get mediaObject => _mediaObject;
  
  /// The media type (audio, video, application)
  String get mediaType => kind;
  
  /// The direction of this media section
  RtpHeaderDirection get direction;
  
  /// Whether this media section is paused
  bool get isPaused;
  
  /// Whether this media section is muted
  bool get isMuted;
  
  /// The RTP parameters for this media section
  RtpParameters get rtpParameters;
  
  /// The codec payload types for this media section
  Map<String, int> get codecPayloads;
  
  /// The extension IDs for this media section
  Map<String, int> get extIds;
  
  /// The RTP capabilities for this media section
  RtpCapabilities get rtpCapabilities;
  
  /// Whether this media section is offering a new DTLS role
  bool get offerRtpDtlsRole;
  
  /// Create a new MediaSection
  MediaSection({
    required this.mid,
    required this.kind,
    this.cname,
    this.enableRtx = false,
    this.enableSrtp = false,
    this.enableSctp = false,
    this.enableUdp = true,
    this.enableTcp = false,
    this.enableRtcpMux = true,
    this.isDataChannel = false,
  }) : _mediaObject = {} {
    _mediaObject['mid'] = mid;
    _mediaObject['type'] = kind;
    _mediaObject['protocol'] = enableSctp 
        ? 'UDP/DTLS/SCTP' 
        : enableSrtp 
            ? 'UDP/TLS/RTP/SAVPF' 
            : 'RTP/AVP';
    _mediaObject['port'] = 7; // Default port (will be updated)
    _mediaObject['connection'] = {'ip': '0.0.0.0', 'version': 4};
    _mediaObject['direction'] = RtpHeaderDirection.inactive.value;
    
    if (enableRtcpMux) {
      _mediaObject['rtcpMux'] = 'rtcp-mux';
    }
    
    if (enableSrtp) {
      _mediaObject['crypto'] = [];
    }
  }
  
  /// Get codec name from MIME type (matches versatica's media_section.ts)
  static String getCodecName(String mimeType) {
    return mimeType.split('/')[1].toLowerCase();
  }
  
  /// Disable this media section
  void disable();
  
  /// Pause this media section
  void pause();
  
  /// Resume this media section
  void resume();
  
  /// Set the RTP parameters for this media section
  void setRtpParameters(RtpParameters rtpParameters);
  
  /// Set the RTP mapping for this media section
  void setRtpMapping(Map<String, dynamic> rtpMapping);
  
  /// Set the DTLS role for this media section
  void setDtlsRole(String role);
  
  /// Set the DTLS parameters for this media section
  void setDtlsParameters(Map<String, dynamic> dtlsParameters);
  
  /// Set the SCTP parameters for this media section
  void setSctpParameters(Map<String, dynamic> sctpParameters);
  
  /// Set the SCTP stream parameters for this media section
  void setSctpStreamParameters(List<dynamic> sctpStreamParameters);
  
  /// Set the maximum message size for this media section
  void setMaxMessageSize(int maxMessageSize);
  
  /// Get the media section as an object
  Map<String, dynamic> getObject();
  
  /// Close this media section
  void close() {
    disable();
    _mediaObject['port'] = 0;
  }
  
  /// Set the direction of this media section
  void setDirection(RtpHeaderDirection direction);
  
  @override
  String toString() {
    return 'MediaSection(mid: $mid, kind: $kind, direction: $direction)';
  }
}

/// Media section for offers
class OfferMediaSection extends MediaSection {
  @override
  final RtpParameters rtpParameters;
  
  @override
  final Map<String, int> codecPayloads;
  
  @override
  final Map<String, int> extIds;
  
  @override
  final RtpCapabilities rtpCapabilities;
  
  @override
  RtpHeaderDirection direction;
  
  @override
  final bool offerRtpDtlsRole;
  
  OfferMediaSection({
    required String mid,
    required String kind,
    required this.rtpParameters,
    required this.codecPayloads,
    required this.extIds,
    required this.rtpCapabilities,
    this.direction = RtpHeaderDirection.sendrecv,
    this.offerRtpDtlsRole = false,
    String? cname,
    bool enableRtx = false,
    bool enableSrtp = false,
    bool enableSctp = false,
    bool enableUdp = true,
    bool enableTcp = false,
    bool enableRtcpMux = true,
    bool isDataChannel = false,
  }) : super(
          mid: mid,
          kind: kind,
          cname: cname,
          enableRtx: enableRtx,
          enableSrtp: enableSrtp,
          enableSctp: enableSctp,
          enableUdp: enableUdp,
          enableTcp: enableTcp,
          enableRtcpMux: enableRtcpMux,
          isDataChannel: isDataChannel,
        ) {
    // Initialize media object
    _mediaObject['direction'] = direction.value;
  }
  
  @override
  bool get isPaused => direction == RtpHeaderDirection.inactive;
  
  @override
  bool get isMuted => direction == RtpHeaderDirection.inactive;
  
  @override
  void disable() {
    direction = RtpHeaderDirection.inactive;
    _mediaObject['direction'] = direction.value;
  }
  
  @override
  void pause() {
    if (direction == RtpHeaderDirection.sendrecv) {
      direction = RtpHeaderDirection.recvonly;
    } else if (direction == RtpHeaderDirection.sendonly) {
      direction = RtpHeaderDirection.inactive;
    }
    _mediaObject['direction'] = direction.value;
  }
  
  @override
  void resume() {
    if (direction == RtpHeaderDirection.recvonly) {
      direction = RtpHeaderDirection.sendrecv;
    } else if (direction == RtpHeaderDirection.inactive) {
      direction = RtpHeaderDirection.sendonly;
    }
    _mediaObject['direction'] = direction.value;
  }
  
  @override
  void setRtpParameters(RtpParameters rtpParameters) {
    // No-op in base class
  }
  
  @override
  void setRtpMapping(Map<String, dynamic> rtpMapping) {
    // No-op in base class
  }
  
  @override
  void setDtlsRole(String role) {
    _mediaObject['setup'] = role == 'client' ? 'active' : 'passive';
  }
  
  @override
  void setDtlsParameters(Map<String, dynamic> dtlsParameters) {
    _mediaObject['fingerprint'] = {
      'type': dtlsParameters['fingerprint']['algorithm'],
      'hash': dtlsParameters['fingerprint']['value'],
    };
    _mediaObject['setup'] = dtlsParameters['role'] == 'client' ? 'active' : 'passive';
  }
  
  @override
  void setSctpParameters(Map<String, dynamic> sctpParameters) {
    _mediaObject['sctp'] = {
      'port': sctpParameters['port'],
      'protocol': sctpParameters['protocol'] ?? 'webrtc-datachannel',
      'streams': sctpParameters['streams'] ?? 65535,
    };
  }
  
  @override
  void setSctpStreamParameters(List<dynamic> sctpStreamParameters) {
    // No-op in base class
  }
  
  @override
  void setMaxMessageSize(int maxMessageSize) {
    _mediaObject['maxMessageSize'] = maxMessageSize;
  }
  
  @override
  Map<String, dynamic> getObject() {
    return {
      'mid': mid,
      'kind': kind,
      'rtpParameters': rtpParameters.toMap(),
      'rtpCapabilities': rtpCapabilities.toMap(),
      'direction': direction.toString().split('.').last,
      'offerRtpDtlsRole': offerRtpDtlsRole,
      'cname': cname,
      'enableRtx': enableRtx,
      'enableSrtp': enableSrtp,
      'enableSctp': enableSctp,
      'enableUdp': enableUdp,
      'enableTcp': enableTcp,
      'enableRtcpMux': enableRtcpMux,
      'isDataChannel': isDataChannel,
    };
  }
  
  @override
  void setDirection(RtpHeaderDirection direction) {
    this.direction = direction;
    _mediaObject['direction'] = direction.value;
  }
}

/// Media section for answers
class AnswerMediaSection extends MediaSection {
  @override
  final RtpParameters rtpParameters;
  
  @override
  final Map<String, int> codecPayloads;
  
  @override
  final Map<String, int> extIds;
  
  @override
  final RtpCapabilities rtpCapabilities;
  
  @override
  RtpHeaderDirection direction;
  
  @override
  final bool offerRtpDtlsRole;
  
  AnswerMediaSection({
    required String mid,
    required String kind,
    required this.rtpParameters,
    required this.codecPayloads,
    required this.extIds,
    required this.rtpCapabilities,
    this.direction = RtpHeaderDirection.sendrecv,
    this.offerRtpDtlsRole = false,
    String? cname,
    bool enableRtx = false,
    bool enableSrtp = false,
    bool enableSctp = false,
    bool enableUdp = true,
    bool enableTcp = false,
    bool enableRtcpMux = true,
    bool isDataChannel = false,
  }) : super(
          mid: mid,
          kind: kind,
          cname: cname,
          enableRtx: enableRtx,
          enableSrtp: enableSrtp,
          enableSctp: enableSctp,
          enableUdp: enableUdp,
          enableTcp: enableTcp,
          enableRtcpMux: enableRtcpMux,
          isDataChannel: isDataChannel,
        ) {
    // Initialize media object
    _mediaObject['direction'] = direction.value;
  }
  
  @override
  bool get isPaused => direction == RtpHeaderDirection.inactive;
  
  @override
  bool get isMuted => direction == RtpHeaderDirection.inactive;
  
  @override
  void disable() {
    direction = RtpHeaderDirection.inactive;
    _mediaObject['direction'] = direction.value;
  }
  
  @override
  void pause() {
    if (direction == RtpHeaderDirection.sendrecv) {
      direction = RtpHeaderDirection.recvonly;
    } else if (direction == RtpHeaderDirection.sendonly) {
      direction = RtpHeaderDirection.inactive;
    }
    _mediaObject['direction'] = direction.value;
  }
  
  @override
  void resume() {
    if (direction == RtpHeaderDirection.recvonly) {
      direction = RtpHeaderDirection.sendrecv;
    } else if (direction == RtpHeaderDirection.inactive) {
      direction = RtpHeaderDirection.sendonly;
    }
    _mediaObject['direction'] = direction.value;
  }
  
  @override
  void setRtpParameters(RtpParameters rtpParameters) {
    // No-op in answer
  }
  
  @override
  void setRtpMapping(Map<String, dynamic> rtpMapping) {
    // No-op in answer
  }
  
  @override
  void setDtlsRole(String role) {
    _mediaObject['setup'] = role == 'client' ? 'active' : 'passive';
  }
  
  @override
  void setDtlsParameters(Map<String, dynamic> dtlsParameters) {
    _mediaObject['fingerprint'] = {
      'type': dtlsParameters['fingerprint']['algorithm'],
      'hash': dtlsParameters['fingerprint']['value'],
    };
    _mediaObject['setup'] = dtlsParameters['role'] == 'client' ? 'active' : 'passive';
  }
  
  @override
  void setSctpParameters(Map<String, dynamic> sctpParameters) {
    _mediaObject['sctp'] = {
      'port': sctpParameters['port'],
      'protocol': sctpParameters['protocol'] ?? 'webrtc-datachannel',
      'streams': sctpParameters['streams'] ?? 65535,
    };
  }
  
  @override
  void setSctpStreamParameters(List<dynamic> sctpStreamParameters) {
    // No-op in answer
  }
  
  @override
  void setMaxMessageSize(int maxMessageSize) {
    _mediaObject['maxMessageSize'] = maxMessageSize;
  }
  
  @override
  Map<String, dynamic> getObject() {
    return {
      'mid': mid,
      'kind': kind,
      'rtpParameters': rtpParameters.toMap(),
      'rtpCapabilities': rtpCapabilities.toMap(),
      'direction': direction.toString().split('.').last,
      'offerRtpDtlsRole': offerRtpDtlsRole,
      'cname': cname,
      'enableRtx': enableRtx,
      'enableSrtp': enableSrtp,
      'enableSctp': enableSctp,
      'enableUdp': enableUdp,
      'enableTcp': enableTcp,
      'enableRtcpMux': enableRtcpMux,
      'isDataChannel': isDataChannel,
    };
  }
  
  @override
  void setDirection(RtpHeaderDirection direction) {
    this.direction = direction;
    _mediaObject['direction'] = direction.value;
  }
}

/// Helper class to create media sections
class MediaSectionFactory {
  /// Create a new media section
  /// Aligns with mediasoup-client v3's createMediaSection
  static MediaSection create({
    required String mid,
    required String kind,
    required RtpParameters rtpParameters,
    required Map<String, int> codecPayloads,
    required Map<String, int> extIds,
    required RtpCapabilities rtpCapabilities,
    RtpHeaderDirection direction = RtpHeaderDirection.sendrecv,
    bool offerRtpDtlsRole = false,
    String? cname,
    bool enableRtx = false,
    bool enableSrtp = false,
    bool enableSctp = false,
    bool enableUdp = true,
    bool enableTcp = false,
    bool enableRtcpMux = true,
    bool isDataChannel = false,
    bool isAnswer = false,
  }) {
    // Validate input parameters
    if (mid.isEmpty) {
      throw 'missing mid';
    }
    if (kind != 'audio' && kind != 'video' && kind != 'application') {
      throw 'invalid kind: $kind';
    }

    // Create the appropriate media section based on whether it's an answer or offer
    if (isAnswer) {
      return AnswerMediaSection(
        mid: mid,
        kind: kind,
        rtpParameters: rtpParameters,
        codecPayloads: codecPayloads,
        extIds: extIds,
        rtpCapabilities: rtpCapabilities,
        direction: direction,
        offerRtpDtlsRole: offerRtpDtlsRole,
        cname: cname,
        enableRtx: enableRtx,
        enableSrtp: enableSrtp,
        enableSctp: enableSctp,
        enableUdp: enableUdp,
        enableTcp: enableTcp,
        enableRtcpMux: enableRtcpMux,
        isDataChannel: isDataChannel,
      );
    } else {
      return OfferMediaSection(
        mid: mid,
        kind: kind,
        rtpParameters: rtpParameters,
        codecPayloads: codecPayloads,
        extIds: extIds,
        rtpCapabilities: rtpCapabilities,
        direction: direction,
        offerRtpDtlsRole: offerRtpDtlsRole,
        cname: cname,
        enableRtx: enableRtx,
        enableSrtp: enableSrtp,
        enableSctp: enableSctp,
        enableUdp: enableUdp,
        enableTcp: enableTcp,
        enableRtcpMux: enableRtcpMux,
        isDataChannel: isDataChannel,
      );
    }
  }
}

 