import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mediasoup_client_flutter/src/common/index.dart';
import 'package:webrtc_interface/webrtc_interface.dart';
import 'package:mediasoup_client_flutter/src/type_conversion.dart';

/// Media kind (audio, video, or application).
enum MediaKind {
  audio,
  video,
  application,
}

extension MediaKindExtension on MediaKind {
  String get value => toString().split('.').last;
  
  static MediaKind fromString(String value) {
    return MediaKind.values.firstWhere(
      (kind) => kind.value == value,
      orElse: () => throw ArgumentError('Invalid MediaKind: $value'),
    );
  }
}

/// The RTP capabilities define what mediasoup or an endpoint can receive at
/// media level.
class RtpCapabilities {
  /// Supported media and RTX codecs.
  final List<RtpCodecCapability> codecs;

  /// Supported RTP header extensions.
  final List<RtpHeaderExtension> headerExtensions;

  /// Supported FEC mechanisms.
  final List<String> fecMechanisms;

  RtpCapabilities({
    this.codecs = const [],
    this.headerExtensions = const [],
    this.fecMechanisms = const [],
  });

  RtpCapabilities.fromMap(Map data)
      : codecs = data['codecs']
            .map<RtpCodecCapability>(
                (codec) => RtpCodecCapability.fromMap(codec))
            .toList(),
        headerExtensions = (data['headerExtensions'] as List<dynamic>)
            .map<RtpHeaderExtension>(
                (headExt) => RtpHeaderExtension.fromMap(headExt))
            .toList(),
        fecMechanisms = data['fecMechanisms'] ?? [];

  static RtpCapabilities copy(
    RtpCapabilities old, {
    List<RtpCodecCapability>? codecs,
    List<RtpHeaderExtension>? headerExtensions,
    List<String>? fecMechanisms,
  }) {
    return RtpCapabilities(
      codecs: codecs ?? List<RtpCodecCapability>.from(old.codecs),
      headerExtensions: headerExtensions ?? List<RtpHeaderExtension>.from(old.headerExtensions),
      fecMechanisms: fecMechanisms ?? List<String>.from(old.fecMechanisms),
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'codecs': codecs.map((RtpCodecCapability codec) => codec.toMap()).toList(),
      'headerExtensions': headerExtensions.map((RtpHeaderExtension ext) => ext.toMap()).toList(),
      'fecMechanisms': fecMechanisms,
    };
  }
}

/// Direction of RTP header extension.
enum RtpHeaderDirection {
  sendrecv,
  sendonly,
  recvonly,
  inactive,
}

extension RtpHeaderDirectionExtension on RtpHeaderDirection {
  static const Map<RtpHeaderDirection, String> _directionToString = {
    RtpHeaderDirection.sendrecv: 'sendrecv',
    RtpHeaderDirection.sendonly: 'sendonly',
    RtpHeaderDirection.recvonly: 'recvonly',
    RtpHeaderDirection.inactive: 'inactive',
  };

  static const Map<String, RtpHeaderDirection> _stringToDirection = {
    'sendrecv': RtpHeaderDirection.sendrecv,
    'sendonly': RtpHeaderDirection.sendonly,
    'recvonly': RtpHeaderDirection.recvonly,
    'inactive': RtpHeaderDirection.inactive,
  };

  static RtpHeaderDirection fromString(String value) {
    return _stringToDirection[value] ?? RtpHeaderDirection.sendrecv;
  }

  String get value => _directionToString[this] ?? 'sendrecv';
  
  bool get canSend => this == RtpHeaderDirection.sendrecv || this == RtpHeaderDirection.sendonly;
  bool get canReceive => this == RtpHeaderDirection.sendrecv || this == RtpHeaderDirection.recvonly;
}

extension RTCRtpMediaTypeExtension on RTCRtpMediaType {
  static const Map<String, RTCRtpMediaType> _stringToMediaType = {
    'audio': RTCRtpMediaType.RTCRtpMediaTypeAudio,
    'video': RTCRtpMediaType.RTCRtpMediaTypeVideo,
    'data': RTCRtpMediaType.RTCRtpMediaTypeData,
  };

  static const Map<RTCRtpMediaType, String> _mediaTypeToString = {
    RTCRtpMediaType.RTCRtpMediaTypeAudio: 'audio',
    RTCRtpMediaType.RTCRtpMediaTypeVideo: 'video',
    RTCRtpMediaType.RTCRtpMediaTypeData: 'data',
  };

  static RTCRtpMediaType fromString(String value) {
    return _stringToMediaType[value] ?? RTCRtpMediaType.RTCRtpMediaTypeAudio;
  }

  String get stringValue => _mediaTypeToString[this] ?? 'audio';
}

/*
 * Provides information on RTCP feedback messages for a specific codec. Those
 * messages can be transport layer feedback messages or codec-specific feedback
 * messages. The list of RTCP feedbacks supported by mediasoup is defined in the
 * supportedRtpCapabilities.ts file.
 */
/// RTCP feedback definition.
class RtcpFeedback {
  /// Feedback type (e.g., 'nack', 'ccm', 'transport-cc').
  final String type;
  
  /// Feedback parameter (e.g., 'pli', 'fir').
  final String? parameter;

  /// Create a new RTCP feedback.
  const RtcpFeedback({
    required this.type,
    this.parameter,
  });

  /// Create from a map.
  factory RtcpFeedback.fromMap(Map<String, dynamic> map) {
    return RtcpFeedback(
      type: map['type'] as String,
      parameter: map['parameter'] as String?,
    );
  }

  /// Convert to a map.
  Map<String, dynamic> toMap() {
    return {
      'type': type,
      if (parameter != null) 'parameter': parameter,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RtcpFeedback && 
           other.type == type && 
           other.parameter == parameter;
  }
  
  @override
  int get hashCode => type.hashCode ^ (parameter?.hashCode ?? 0);
  
  @override
  String toString() {
    return 'RtcpFeedback(type: $type, parameter: $parameter)';
  }
}

class ExtendedRtpCodec {
  final RTCRtpMediaType kind;
  final String mimeType;
  final int clockRate;
  final int? channels;
  final List<RtcpFeedback> rtcpFeedback;
  int? localPayloadType;
  int? localRtxPayloadType;
  int? remotePayloadType;
  int? remoteRtxPayloadType;
  final Map<String, dynamic> localParameters;
  final Map<String, dynamic> remoteParameters;

  ExtendedRtpCodec({
    required this.kind,
    required this.mimeType,
    required this.clockRate,
    this.channels = 1,
    this.rtcpFeedback = const [],
    this.localPayloadType,
    this.localRtxPayloadType,
    this.remotePayloadType,
    this.remoteRtxPayloadType,
    required this.localParameters,
    required this.remoteParameters,
  });

  factory ExtendedRtpCodec.fromMap(Map<String, dynamic> map) {
    return ExtendedRtpCodec(
      kind: RTCRtpMediaTypeExtension.fromString(map['kind']),
      mimeType: map['mimeType'],
      clockRate: map['clockRate'],
      channels: map['channels'],
      rtcpFeedback: (map['rtcpFeedback'] as List<dynamic>)
          .map<RtcpFeedback>((fb) => RtcpFeedback.fromMap(fb))
          .toList(),
      localPayloadType: map['localPayloadType'],
      localRtxPayloadType: map['localRtxPayloadType'],
      remotePayloadType: map['remotePayloadType'],
      remoteRtxPayloadType: map['remoteRtxPayloadType'],
      localParameters: Map<String, dynamic>.from(map['localParameters'] ?? {}),
      remoteParameters: Map<String, dynamic>.from(map['remoteParameters'] ?? {}),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'kind': TypeConversion.rtcMediaTypeToString(kind),
      'mimeType': mimeType == 'rtx' ? '${TypeConversion.rtcMediaTypeToString(kind)}/rtx' : mimeType,
      'clockRate': clockRate,
      'channels': channels,
      'localPayloadType': localPayloadType,
      'localRtxPayloadType': localRtxPayloadType,
      'remotePayloadType': remotePayloadType,
      'remoteRtxPayloadType': remoteRtxPayloadType,
      'localParameters': localParameters,
      'remoteParameters': remoteParameters,
      'rtcpFeedback': rtcpFeedback,
    };
  }
}

class ExtendedRtpHeaderExtension {
  final RTCRtpMediaType kind;
  final String uri;
  final int sendId;
  final int recvId;
  final bool encrypt;
  final RtpHeaderDirection direction;

  ExtendedRtpHeaderExtension({
    required this.kind,
    required this.uri,
    required this.sendId,
    required this.recvId,
    required this.encrypt,
    required this.direction,
  });

  factory ExtendedRtpHeaderExtension.fromMap(Map<String, dynamic> map) {
    return ExtendedRtpHeaderExtension(
      kind: RTCRtpMediaTypeExtension.fromString(map['kind']),
      uri: map['uri'],
      sendId: map['sendId'],
      recvId: map['recvId'],
      encrypt: map['encrypt'],
      direction: RtpHeaderDirectionExtension.fromString(map['direction']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'kind': TypeConversion.rtcMediaTypeToString(kind),
      'uri': uri,
      'sendId': sendId,
      'recvId': recvId,
      'encrypt': encrypt,
      'direction': direction.value,
    };
  }
}

class RtpCodecCapability {
  /*
   * Media kind.
   */
  final MediaKind kind;

  /*
   * The codec MIME media type/subtype (e.g. 'audio/opus', 'video/VP8').
   */
  final String mimeType;

  /*
   * The preferred RTP payload type.
   */
  final int? preferredPayloadType;

  /*
   * Codec clock rate expressed in Hertz.
   */
  final int clockRate;

  /*
   * The number of channels supported (e.g. two for stereo). Just for audio.
   * Default 1.
   */
  final int? channels;

  /*
   * Codec specific parameters. Some parameters (such as 'packetization-mode'
   * and 'profile-level-id' in H264 or 'profile-id' in VP9) are critical for
   * codec matching.
   */
  Map<String, dynamic> parameters;

  /*
   * Transport layer and codec-specific feedback messages for this codec.
   */
  final List<RtcpFeedback> rtcpFeedback;

  RtpCodecCapability({
    required this.kind,
    required this.mimeType,
    this.preferredPayloadType,
    required this.clockRate,
    this.channels = 1,
    this.parameters = const {},
    this.rtcpFeedback = const [],
  });

  RtpCodecCapability.fromMap(Map<String, dynamic> data)
      : kind = MediaKindExtension.fromString(data['kind']),
        mimeType = data['mimeType'],
        preferredPayloadType = data['preferredPayloadType'],
        clockRate = data['clockRate'],
        channels = data['channels'],
        parameters = Map<String, dynamic>.from(data['parameters'] ?? {}),
        rtcpFeedback = (data['rtcpFeedback'] as List<dynamic>?)
            ?.map<RtcpFeedback>((rtcpFb) => RtcpFeedback.fromMap(rtcpFb))
            .toList() ?? [];

  Map<String, dynamic> toMap() {
    return {
      'kind': kind.value,
      'mimeType': mimeType,
      'preferredPayloadType': preferredPayloadType,
      'clockRate': clockRate,
      'channels': channels,
      'parameters': parameters,
      'rtcpFeedback': rtcpFeedback.map((RtcpFeedback fb) => fb.toMap()).toList(),
    };
  }
}

class RtpHeaderExtension {
  /*
   * Media kind. If empty string, it's valid for all kinds.
   * Default any media kind.
   */
  final MediaKind? kind;

  /*
   * The URI of the RTP header extension, as defined in RFC 5285.
   */
  final String uri;

  /*
   * The preferred numeric identifier that goes in the RTP packet. Must be
   * unique.
   */
  final int preferredId;

  /*
   * If true, it is preferred that the value in the header be encrypted as per
   * RFC 6904. Default false.
   */
  final bool preferredEncrypt;

  /*
   * If 'sendrecv', mediasoup supports sending and receiving this RTP extension.
   * 'sendonly' means that mediasoup can send (but not receive) it. 'recvonly'
   * means that mediasoup can receive (but not send) it.
   */
  final RtpHeaderDirection direction;

  RtpHeaderExtension({
    this.kind,
    required this.uri,
    required this.preferredId,
    this.preferredEncrypt = false,
    this.direction = RtpHeaderDirection.sendrecv,
  });

  RtpHeaderExtension.fromMap(Map<String, dynamic> data)
      : kind = data['kind'] != null ? MediaKindExtension.fromString(data['kind']) : null,
        uri = data['uri'],
        preferredId = data['preferredId'],
        preferredEncrypt = data['preferredEncrypt'] ?? false,
        direction = RtpHeaderDirectionExtension.fromString(data['direction'] ?? 'sendrecv');

  Map<String, dynamic> toMap() {
    return {
      if (kind != null) 'kind': kind!.value,
      'uri': uri,
      'preferredId': preferredId,
      'preferredEncrypt': preferredEncrypt,
      'direction': direction.value,
    };
  }
}

class Rtx {
  final int ssrc;

  Rtx({required this.ssrc});

  Rtx.fromMap(Map<String, dynamic> data) : ssrc = data['ssrc'];

  Map<String, dynamic> toMap() {
    return {'ssrc': ssrc};
  }
}

/// Defines a RTP header extension within the RTP parameters.
class RtpHeaderExtensionParameters {
  /*
   * The URI of the RTP header extension, as defined in RFC 5285.
   */
  final String uri;

  /*
   * The numeric identifier that goes in the RTP packet. Must be unique.
   */
  final int id;

  /*
   * If true, the value in the header is encrypted as per RFC 6904. Default false.
   */
  final bool encrypt;

  /*
   * Configuration parameters for the header extension.
   */
  final Map<String, dynamic> parameters;

  RtpHeaderExtensionParameters({
    required this.uri,
    required this.id,
    this.encrypt = false,
    this.parameters = const {},
  });

  RtpHeaderExtensionParameters.fromMap(Map<String, dynamic> data)
      : uri = data['uri'],
        id = data['id'],
        encrypt = data['encrypt'] ?? false,
        parameters = Map<String, dynamic>.from(data['parameters'] ?? {});

  Map<String, dynamic> toMap() {
    return {
      'uri': uri,
      'id': id,
      'encrypt': encrypt,
      'parameters': parameters,
    };
  }
}

class RtpEncodingParameters {
  /*
   * The RTP stream ID (RID) value as defined in the "RTP Stream Identifier" source.
   * It must be unique.
   */
  String? rid;

  /*
   * Whether this encoding is actively being sent. Default true.
   */
  bool active;

  /*
   * The maximum bitrate that can be used by this encoding.
   */
  final int? maxBitrate;

  /*
   * The maximum framerate that can be used by this encoding (in frames per second).
   */
  final double? maxFramerate;

  /*
   * The minimum bitrate that can be used by this encoding.
   */
  final int? minBitrate;

  /*
   * The number of temporal layers to use for this encoding.
   */
  final int? numTemporalLayers;

  /*
   * The factor by which to scale down the resolution of this encoding.
   */
  final double? scaleResolutionDownBy;

  /*
   * The SSRC for this encoding.
   */
  final int? ssrc;

  /*
   * Codec payload type this encoding affects. If unset, first media codec is
   * chosen.
   */
  final int? codecPayloadType;

  /*
   * RTX stream information. It must contain a numeric ssrc field indicating
   * the RTX SSRC.
   */
  Rtx? rtx;

  /*
   * It indicates whether discontinuous RTP transmission will be used. Useful
   * for audio (if the codec supports it) and for video screen sharing (when
   * static content is being transmitted, this option disables the RTP
   * inactivity checks in mediasoup). Default false.
   */
  final bool? dtx;

  /*
   * Number of spatial and temporal layers in the RTP stream (e.g. 'L1T3').
   * See webrtc-svc.
   */
  final String? scalabilityMode;

  RtpEncodingParameters({
    this.rid,
    this.active = true,
    this.maxBitrate,
    this.maxFramerate,
    this.minBitrate,
    this.numTemporalLayers,
    this.scaleResolutionDownBy,
    this.ssrc,
    this.codecPayloadType,
    this.rtx,
    this.dtx,
    this.scalabilityMode,
  });

  factory RtpEncodingParameters.fromMap(Map<String, dynamic> data) {
    return RtpEncodingParameters(
      rid: data['rid'],
      active: data['active'] ?? true,
      maxBitrate: data['maxBitrate'],
      maxFramerate: data['maxFramerate']?.toDouble(),
      minBitrate: data['minBitrate'],
      numTemporalLayers: data['numTemporalLayers'],
      scaleResolutionDownBy: data['scaleResolutionDownBy']?.toDouble(),
      ssrc: data['ssrc'],
      codecPayloadType: data['codecPayloadType'],
      rtx: data['rtx'] != null ? Rtx.fromMap(data['rtx']) : null,
      dtx: data['dtx'],
      scalabilityMode: data['scalabilityMode'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (rid != null) 'rid': rid,
      'active': active,
      if (maxBitrate != null) 'maxBitrate': maxBitrate,
      if (maxFramerate != null) 'maxFramerate': maxFramerate,
      if (minBitrate != null) 'minBitrate': minBitrate,
      if (numTemporalLayers != null) 'numTemporalLayers': numTemporalLayers,
      if (scaleResolutionDownBy != null) 'scaleResolutionDownBy': scaleResolutionDownBy,
      if (ssrc != null) 'ssrc': ssrc,
      if (codecPayloadType != null) 'codecPayloadType': codecPayloadType,
      if (rtx != null) 'rtx': rtx!.toMap(),
      if (dtx != null) 'dtx': dtx,
      if (scalabilityMode != null) 'scalabilityMode': scalabilityMode,
    };
  }

  static RtpEncodingParameters assign(
      RtpEncodingParameters prev, RtpEncodingParameters next) {
    return RtpEncodingParameters(
      rid: next.rid ?? prev.rid,
      active: next.active,
      maxBitrate: next.maxBitrate ?? prev.maxBitrate,
      maxFramerate: next.maxFramerate ?? prev.maxFramerate,
      minBitrate: next.minBitrate ?? prev.minBitrate,
      numTemporalLayers: next.numTemporalLayers ?? prev.numTemporalLayers,
      scaleResolutionDownBy: next.scaleResolutionDownBy ?? prev.scaleResolutionDownBy,
      ssrc: next.ssrc ?? prev.ssrc,
      codecPayloadType: next.codecPayloadType ?? prev.codecPayloadType,
      rtx: next.rtx ?? prev.rtx,
      dtx: next.dtx ?? prev.dtx,
      scalabilityMode: next.scalabilityMode ?? prev.scalabilityMode,
    );
  }
}

/// Provides information on codec settings within the RTP parameters. The list
/// of media codecs supported by mediasoup and their settings is defined in the
/// supportedRtpCapabilities.ts file.
class RtpCodecParameters {
  /// The codec MIME media type/subtype (e.g. 'audio/opus', 'video/VP8').
  final String mimeType;

  /// The value that goes in the RTP Payload Type Field. Must be unique.
  final int payloadType;

  /// Codec clock rate expressed in Hertz.
  final int clockRate;

  /// The number of channels supported (e.e two for stereo). Just for audio.
  /// Default 1.
  final int? channels;

  /// Codec-specific parameters available for signaling. Some parameters (such
  /// as 'packetization-mode' and 'profile-level-id' in H264 or 'profile-id' in
  /// VP9) are critical for codec matching.
  final Map<String, dynamic> parameters;

  /// Transport layer and codec-specific feedback messages for this codec.
  final List<RtcpFeedback> rtcpFeedback;

  RtpCodecParameters({
    required this.mimeType,
    required this.payloadType,
    required this.clockRate,
    this.channels = 1,
    this.parameters = const {},
    this.rtcpFeedback = const [],
  });

  RtpCodecParameters.fromMap(Map<String, dynamic> data)
      : mimeType = data['mimeType'],
        payloadType = data['payloadType'],
        clockRate = data['clockRate'],
        channels = data['channels'],
        parameters = Map<String, dynamic>.from(data['parameters'] ?? {}),
        rtcpFeedback = (data['rtcpFeedback'] as List<dynamic>?)
            ?.map<RtcpFeedback>((e) => RtcpFeedback.fromMap(e))
            .toList() ?? [];

  Map<String, dynamic> toMap() {
    return {
      'mimeType': mimeType,
      'payloadType': payloadType,
      'clockRate': clockRate,
      'channels': channels,
      'parameters': parameters,
      'rtcpFeedback': rtcpFeedback.map((RtcpFeedback rtcpFB) => rtcpFB.toMap()).toList(),
    };
  }
}

/// The RTP send parameters describe a media stream received by mediasoup from
/// an endpoint through its corresponding mediasoup Producer. These parameters
/// may include a mid value that the mediasoup transport will use to match
/// received RTP packets based on their MID RTP extension value.
///
/// mediasoup allows RTP send parameters with a single encoding and with multiple
/// encodings (simulcast). In the latter case, each entry in the encodings array
/// must include a ssrc field or a rid field (the RID RTP extension value). Check
/// the Simulcast and SVC sections for more information.
///
/// The RTP receive parameters describe a media stream as sent by mediasoup to
/// an endpoint through its corresponding mediasoup Consumer. The mid value is
/// unset (mediasoup does not include the MID RTP extension into RTP packets
/// being sent to endpoints).
///
/// There is a single entry in the encodings array (even if the corresponding
/// producer uses simulcast). The consumer sends a single and continuous RTP
/// stream to the endpoint and spatial/temporal layer selection is possible via
/// consumer.setPreferredLayers().
///
/// As an exception, previous bullet is not true when consuming a stream over a
/// PipeTransport, in which all RTP streams from the associated producer are
/// forwarded verbatim through the consumer.
///
/// The RTP receive parameters will always have their ssrc values randomly
/// generated for all of its  encodings (and optional rtx: { ssrc: XXXX } if the
/// endpoint supports RTX), regardless of the original RTP send parameters in
/// the associated producer. This applies even if the producer's encodings have
/// rid set.
class RtpParameters {
  /// The MID RTP extension value as defined in the BUNDLE specification.
  final String? mid;

  /// Media and RTX codecs in use.
  final List<RtpCodecParameters> codecs;

  /// RTP header extensions in use.
  final List<RtpHeaderExtensionParameters> headerExtensions;

  /// Transmitted RTP streams and their settings.
  final List<RtpEncodingParameters> encodings;

  /// Parameters used for RTCP.
  final RtcpParameters? rtcp;

  RtpParameters({
    this.mid,
    this.codecs = const [],
    this.headerExtensions = const [],
    this.encodings = const [],
    this.rtcp,
  });

  RtpParameters.fromMap(Map<String, dynamic> data)
      : mid = data['mid'],
        codecs = (data['codecs'] as List<dynamic>)
            .map<RtpCodecParameters>((codec) => RtpCodecParameters.fromMap(codec))
            .toList(),
        headerExtensions = (data['headerExtensions'] as List<dynamic>)
            .map<RtpHeaderExtensionParameters>((headerExtension) => RtpHeaderExtensionParameters.fromMap(headerExtension))
            .toList(),
        encodings = (data['encodings'] as List<dynamic>)
            .map<RtpEncodingParameters>((encoding) => RtpEncodingParameters.fromMap(encoding))
            .toList(),
        rtcp = data['rtcp'] != null ? RtcpParameters.fromMap(data['rtcp']) : null;

  static RtpParameters copy(
    RtpParameters old, {
    String? mid,
    List<RtpCodecParameters>? codecs,
    List<RtpHeaderExtensionParameters>? headerExtensions,
    List<RtpEncodingParameters>? encodings,
    RtcpParameters? rtcp,
  }) {
    return RtpParameters(
      mid: mid ?? old.mid,
      codecs: codecs ?? List<RtpCodecParameters>.from(old.codecs),
      headerExtensions: headerExtensions ?? List<RtpHeaderExtensionParameters>.from(old.headerExtensions),
      encodings: encodings ?? List<RtpEncodingParameters>.from(old.encodings),
      rtcp: rtcp ?? (old.rtcp != null ? RtcpParameters.copy(old.rtcp!) : null),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (mid != null) 'mid': mid,
      'codecs': codecs.map((RtpCodecParameters codec) => codec.toMap()).toList(),
      'headerExtensions': headerExtensions.map((RtpHeaderExtensionParameters ext) => ext.toMap()).toList(),
      'encodings': encodings.map((RtpEncodingParameters encoding) => encoding.toMap()).toList(),
      if (rtcp != null) 'rtcp': rtcp!.toMap(),
    };
  }
}

/// Provides information on RTCP settings within the RTP parameters.
///
/// If no cname is given in a producer's RTP parameters, the mediasoup transport
/// will choose a random one that will be used into RTCP SDES messages sent to
/// all its associated consumers.
///
/// mediasoup assumes reducedSize to always be true.
class RtcpParameters {
  /// The Canonical Name (CNAME) used by RTCP.
  final String cname;

  /// Whether reduced-size RTCP is used. Default true.
  final bool reducedSize;

  /// Whether RTCP-mux is used. Default true.
  final bool mux;

  RtcpParameters({
    required this.cname,
    this.reducedSize = true,
    this.mux = true,
  });

  factory RtcpParameters.fromMap(Map<String, dynamic> data) {
    return RtcpParameters(
      cname: data['cname'] ?? '',
      reducedSize: data['reducedSize'] ?? true,
      mux: data['mux'] ?? true,
    );
  }

  static RtcpParameters copy(
    RtcpParameters old, {
    String? cname,
    bool? reducedSize,
    bool? mux,
  }) {
    return RtcpParameters(
      cname: cname ?? old.cname,
      reducedSize: reducedSize ?? old.reducedSize,
      mux: mux ?? old.mux,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'cname': cname,
      'reducedSize': reducedSize,
      'mux': mux,
    };
  }
}