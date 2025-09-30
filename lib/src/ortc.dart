import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mediasoup_client_flutter/src/rtp_parameters.dart';
import 'package:mediasoup_client_flutter/src/sctp_parameters.dart';
import 'package:mediasoup_client_flutter/src/type_conversion.dart';
import 'package:h264_profile_level_id/h264_profile_level_id.dart';

String RTP_PROBATOR_MID = 'probator';
int RTP_PROBATOR_SSRC = 1234;
int RTP_PROBATOR_CODEC_PAYLOAD_TYPE = 127;

class Ortc {
  /// Validates RtcpFeedback. It may modify given data by adding missing
  /// fields with default values.
  /// It throws if invalid.
  static RtcpFeedback validateRtcpFeedback(RtcpFeedback fb) {
    // type is mandatory.
    if (fb.type.isEmpty) {
      throw ('missing fb.type');
    }

    // parameter is optional. If unset set it to an empty string.
    String parameter = fb.parameter ?? '';

    return RtcpFeedback(
      type: fb.type,
      parameter: parameter.isNotEmpty ? parameter : null,
    );
  }

  /// Validates RtpCodecCapability. It may modify given data by adding missing
  /// fields with default values.
  /// It throws if invalid.
  static RtpCodecCapability validateRtpCodecCapability(RtpCodecCapability codec) {
    RegExp mimeTypeRegex = RegExp(r"^(audio|video)/(.+)", caseSensitive: true);

    // mimeType is mandatory.
    if (codec.mimeType.isEmpty) {
      throw ('missing codec.mimeType');
    }

    Iterable<RegExpMatch> mimeTypeMatch = mimeTypeRegex.allMatches(codec.mimeType);

    if (mimeTypeMatch.isEmpty) {
      throw ('invalid codec.mimeType');
    }

    // Get kind from mimeType
    final kind = MediaKindExtension.fromString(mimeTypeMatch.first.group(1)!.toLowerCase());

    // channels is optional. If unset, set it to 1 (just if audio).
    int? channels = codec.channels;
    if (kind == MediaKind.audio && channels == null) {
      channels = 1;
    } else if (kind != MediaKind.audio) {
      channels = null;
    }

    // Validate parameters
    final parameters = Map<String, dynamic>.from(codec.parameters);
    for (var key in parameters.keys) {
      var value = parameters[key];

      if (value == null) {
        parameters[key] = '';
        value = '';
      }

      if (value is! String && value is! int) {
        throw ('invalid codec parameter [key:$key, value:$value]');
      }

      // Specific parameters validation.
      if (key == 'apt') {
        if (value is! int) {
          throw ('invalid codec apt parameter');
        }
      }
    }

    // Validate rtcpFeedback
    final rtcpFeedback = codec.rtcpFeedback.map(validateRtcpFeedback).toList();

    return RtpCodecCapability(
      kind: kind,
      mimeType: codec.mimeType,
      preferredPayloadType: codec.preferredPayloadType,
      clockRate: codec.clockRate,
      channels: channels,
      parameters: parameters,
      rtcpFeedback: rtcpFeedback,
    );
  }

  /// Validates RtpHeaderExtension. It may modify given data by adding missing
  /// fields with default values.
  /// It throws if invalid.
  static RtpHeaderExtension validateRtpHeaderExtension(RtpHeaderExtension ext) {
    // uri is mandatory.
    if (ext.uri.isEmpty) {
      throw ('missing ext.uri');
    }

    // preferredId is mandatory.
    if (ext.preferredId == null) {
      throw ('missing ext.preferredId');
    }

    // preferredEncrypt is optional. If unset set it to false.
    bool preferredEncrypt = ext.preferredEncrypt ?? false;

    // direction is optional. If unset set it to sendrecv.
    RtpHeaderDirection direction = ext.direction ?? RtpHeaderDirection.sendrecv;

    return RtpHeaderExtension(
      kind: ext.kind,
      uri: ext.uri,
      preferredId: ext.preferredId!,
      preferredEncrypt: preferredEncrypt,
      direction: direction,
    );
  }

  /// Validates RtpCapabilities. It may modify given data by adding missing
  /// fields with default values.
  /// It throws if invalid.
  static RtpCapabilities validateRtpCapabilities(RtpCapabilities caps) {
    // Validate codecs
    final codecs = caps.codecs.map(validateRtpCodecCapability).toList();

    // Validate header extensions
    final headerExtensions = caps.headerExtensions.map(validateRtpHeaderExtension).toList();

    return RtpCapabilities(
      codecs: codecs,
      headerExtensions: headerExtensions,
      fecMechanisms: List<String>.from(caps.fecMechanisms),
    );
  }

  /// Validates RtpHeaderExtensionParameters. It may modify given data by adding missing
  /// fields with default values.
  /// It throws if invalid.
  static RtpHeaderExtensionParameters validateRtpHeaderExtensionParameters(RtpHeaderExtensionParameters ext) {
    // uri is mandatory.
    if (ext.uri.isEmpty) {
      throw ('missing ext.uri');
    }

    // id is mandatory.
    if (ext.id == null) {
      throw ('missing ext.id');
    }

    // encrypt is optional. If unset set it to false.
    bool encrypt = ext.encrypt ?? false;

    // Validate parameters
    final parameters = Map<String, dynamic>.from(ext.parameters);
    for (var key in parameters.keys) {
      var value = parameters[key];
      if (value == null) {
        parameters[key] = '';
        value = '';
      }

      if (value is! String && value is! int) {
        throw ('invalid header extension parameter');
      }
    }

    return RtpHeaderExtensionParameters(
      uri: ext.uri,
      id: ext.id!,
      encrypt: encrypt,
      parameters: parameters,
    );
  }

  static void validateSctpStreamParameters(SctpStreamParameters parameters) {
    if (parameters.streamId == null) {
      throw ('missing streamId');
    }
    if (parameters.ordered == null) {
      throw ('missing ordered');
    }
    // Versatica-style validation
    if (parameters.streamId! < 0) {
      throw ('invalid streamId');
    }
    if (parameters.maxPacketLifeTime != null && parameters.maxPacketLifeTime! < 0) {
      throw ('invalid maxPacketLifeTime');
    }
    if (parameters.maxRetransmits != null && parameters.maxRetransmits! < 0) {
      throw ('invalid maxRetransmits');
    }
  }

  /// Validates RtpEncodingParameters. It may modify given data by adding missing
  /// fields with default values.
  /// It throws if invalid.
  static RtpEncodingParameters validateRtpEncodingParameters(RtpEncodingParameters encoding) {
    // dtx is optional. If unset set it to false.
    bool dtx = encoding.dtx ?? false;

    return RtpEncodingParameters(
      rid: encoding.rid,
      active: encoding.active,
      maxBitrate: encoding.maxBitrate,
      maxFramerate: encoding.maxFramerate,
      minBitrate: encoding.minBitrate,
      numTemporalLayers: encoding.numTemporalLayers,
      scaleResolutionDownBy: encoding.scaleResolutionDownBy,
      ssrc: encoding.ssrc,
      codecPayloadType: encoding.codecPayloadType,
      rtx: encoding.rtx,
      dtx: dtx,
      scalabilityMode: encoding.scalabilityMode,
    );
  }

  /// Validates RtcpParameters. It may modify given data by adding missing
  /// fields with default values.
  /// It throws if invalid.
  static RtcpParameters validateRtcpParameters(RtcpParameters rtcp) {
    // reducedSize is optional. If unset set it to true.
    bool reducedSize = rtcp.reducedSize ?? true;
    
    // mux is optional. If unset set it to true.
    bool mux = rtcp.mux ?? true;

    return RtcpParameters(
      cname: rtcp.cname,
      reducedSize: reducedSize,
      mux: mux,
    );
  }

  /// Validates RtpCodecParameters. It may modify given data by adding missing
  /// fields with default values.
  /// It throws if invalid.
  static RtpCodecParameters validateRtpCodecParameters(RtpCodecParameters codec) {
    final RegExp mimeTypeRegex = RegExp(r"^(audio|video)/(.+)", caseSensitive: true);

    // mimeType is mandatory.
    if (codec.mimeType.isEmpty) {
      throw ('missing codec.mimeType');
    }

    final Iterable<RegExpMatch> mimeTypeMatch = mimeTypeRegex.allMatches(codec.mimeType);

    if (mimeTypeMatch.isEmpty) {
      throw ('invalid codec.mimeType');
    }

    // Get kind from mimeType
    final kind = MediaKindExtension.fromString(mimeTypeMatch.first.group(1)!.toLowerCase());

    // channels is optional. If unset, set it to 1 (just if audio).
    int? channels = codec.channels;
    if (kind == MediaKind.audio && channels == null) {
      channels = 1;
    } else if (kind != MediaKind.audio) {
      channels = null;
    }

    // Validate parameters
    final parameters = Map<String, dynamic>.from(codec.parameters);
    for (var key in parameters.keys) {
      var value = parameters[key];
      if (value == null) {
        parameters[key] = '';
        value = '';
      }

      if (value is! String && value is! int) {
        throw ('invalid codec parameter [key:$key, value:$value]');
      }

      // Specific parameters validation.
      if (key == 'apt') {
        if (value is! int) {
          throw ('invalid codec apt parameter');
        }
      }
    }

    // Validate rtcpFeedback
    final rtcpFeedback = codec.rtcpFeedback.map(validateRtcpFeedback).toList();

    return RtpCodecParameters(
      mimeType: codec.mimeType,
      payloadType: codec.payloadType,
      clockRate: codec.clockRate,
      channels: channels,
      parameters: parameters,
      rtcpFeedback: rtcpFeedback,
    );
  }

  /// Validates RtpParameters. It may modify given data by adding missing
  /// fields with default values.
  /// It throws if invalid.
  static RtpParameters validateRtpParameters(RtpParameters params) {
    // Validate codecs
    final codecs = params.codecs.map(validateRtpCodecParameters).toList();

    // Validate header extensions
    final headerExtensions = params.headerExtensions.map(validateRtpHeaderExtensionParameters).toList();

    // Validate encodings
    final encodings = params.encodings.map(validateRtpEncodingParameters).toList();

    // Validate rtcp
    final rtcp = params.rtcp != null ? validateRtcpParameters(params.rtcp!) : null;

    return RtpParameters(
      mid: params.mid,
      codecs: codecs,
      headerExtensions: headerExtensions,
      encodings: encodings,
      rtcp: rtcp,
    );
  }

  static bool isRtxCodec(RtpCodecCapability codec) {
    return codec.mimeType.toLowerCase().endsWith('/rtx');
  }

  static bool matchCodecs({
    required RtpCodecCapability aCodec,
    required RtpCodecCapability bCodec,
    bool strict = false,
    bool modify = false,
  }) {
    String aMimeType = aCodec.mimeType.toLowerCase();
    String bMimeType = bCodec.mimeType.toLowerCase();

    if (aMimeType != bMimeType) {
      return false;
    }

    if (aCodec.clockRate != bCodec.clockRate) {
      return false;
    }

    if (aCodec.channels != bCodec.channels) {
      return false;
    }

    // Per codec special checks.
    switch (aMimeType) {
      case 'video/h264':
        {
          var aPacketizationMode = aCodec.parameters['packetization-mode'] ?? 0;
          var bPacketizationMode = bCodec.parameters['packetization-mode'] ?? 0;

          if (aPacketizationMode != bPacketizationMode) {
            return false;
          }

          // If strict matching check profile-level-id.
          if (strict) {
            if (!H264Utils.isSameProfile(aCodec.parameters, bCodec.parameters)) {
              return false;
            }

            String? selectedProfileLevelId;

            try {
              selectedProfileLevelId = H264Utils.generateProfileLevelIdForAnswer(
                local_supported_params: aCodec.parameters,
                remote_offered_params: bCodec.parameters,
              );
            } catch (error) {
              return false;
            }

            if (modify) {
              // Note: We can't modify immutable objects, so this would need to be handled differently
              // by creating new objects with the modified parameters
            }
          }
          break;
        }

      case 'video/vp9':
        {
          // If strict matching check profile-id.
          if (strict) {
            var aProfileId = aCodec.parameters['profile-id'] ?? 0;
            var bProfileId = bCodec.parameters['profile-id'] ?? 0;

            if (aProfileId != bProfileId) {
              return false;
            }
          }
          break;
        }
    }

    return true;
  }

  static List<RtcpFeedback> reduceRtcpFeedback(RtpCodecCapability codecA, RtpCodecCapability codecB) {
    List<RtcpFeedback> reducedRtcpFeedback = [];

    for (RtcpFeedback aFb in codecA.rtcpFeedback) {
      RtcpFeedback? matchingBFb = codecB.rtcpFeedback.firstWhereOrNull(
        (bFb) => bFb.type == aFb.type && (bFb.parameter == aFb.parameter || (bFb.parameter == null && aFb.parameter == null)),
      );

      if (matchingBFb != null) {
        reducedRtcpFeedback.add(matchingBFb);
      }
    }

    return reducedRtcpFeedback;
  }

  static bool matchHeaderExtensions(RtpHeaderExtension aExt, RtpHeaderExtension bExt) {
    if (aExt.kind != null && bExt.kind != null && aExt.kind != bExt.kind) {
      return false;
    }

    if (aExt.uri != bExt.uri) {
      return false;
    }

    return true;
  }

  /// Generate extended RTP capabilities for sending and receiving.
  static ExtendedRtpCapabilities getExtendedRtpCapabilities(
    RtpCapabilities localCaps,
    RtpCapabilities remoteCaps,
  ) {
    final extendedRtpCapabilities = ExtendedRtpCapabilities(
      codecs: [],
      headerExtensions: [],
    );

    // Match media codecs and keep the order preferred by remoteCaps.
    for (RtpCodecCapability remoteCodec in remoteCaps.codecs) {
      if (isRtxCodec(remoteCodec)) {
        continue;
      }

      final RtpCodecCapability? matchingLocalCodec = localCaps.codecs.firstWhereOrNull(
        (localCodec) => matchCodecs(aCodec: localCodec, bCodec: remoteCodec, strict: true, modify: true),
      );

      if (matchingLocalCodec == null) {
        continue;
      }

      final extendedCodec = ExtendedRtpCodec(
        kind: TypeConversion.mediaKindToRtc(matchingLocalCodec.kind),
        mimeType: matchingLocalCodec.mimeType,
        clockRate: matchingLocalCodec.clockRate,
        channels: matchingLocalCodec.channels,
        rtcpFeedback: reduceRtcpFeedback(matchingLocalCodec, remoteCodec),
        localPayloadType: matchingLocalCodec.preferredPayloadType,
        localRtxPayloadType: null,
        remotePayloadType: remoteCodec.preferredPayloadType,
        remoteRtxPayloadType: null,
        localParameters: Map<String, dynamic>.from(matchingLocalCodec.parameters),
        remoteParameters: Map<String, dynamic>.from(remoteCodec.parameters),
      );

      extendedRtpCapabilities.codecs.add(extendedCodec);
    }

    // Match RTX codecs.
    for (ExtendedRtpCodec extendedCodec in extendedRtpCapabilities.codecs) {
      final RtpCodecCapability? matchingLocalRtxCodec = localCaps.codecs.firstWhereOrNull(
        (localCodec) => isRtxCodec(localCodec) && localCodec.parameters['apt'] == extendedCodec.localPayloadType,
      );

      final RtpCodecCapability? matchingRemoteRtxCodec = remoteCaps.codecs.firstWhereOrNull(
        (remoteCodec) => isRtxCodec(remoteCodec) && remoteCodec.parameters['apt'] == extendedCodec.remotePayloadType,
      );

      if (matchingLocalRtxCodec != null && matchingRemoteRtxCodec != null) {
        extendedCodec.localRtxPayloadType = matchingLocalRtxCodec.preferredPayloadType;
        extendedCodec.remoteRtxPayloadType = matchingRemoteRtxCodec.preferredPayloadType;
      }
    }

    // Match header extensions.
    for (RtpHeaderExtension remoteExt in remoteCaps.headerExtensions) {
      final RtpHeaderExtension? matchingLocalExt = localCaps.headerExtensions.firstWhereOrNull(
        (localExt) => matchHeaderExtensions(localExt, remoteExt),
      );

      if (matchingLocalExt == null) {
        continue;
      }

      var direction = RtpHeaderDirection.sendrecv;
      switch (remoteExt.direction) {
        case RtpHeaderDirection.recvonly:
          direction = RtpHeaderDirection.sendonly;
          break;
        case RtpHeaderDirection.sendonly:
          direction = RtpHeaderDirection.recvonly;
          break;
        case RtpHeaderDirection.inactive:
          direction = RtpHeaderDirection.inactive;
          break;
        case RtpHeaderDirection.sendrecv:
        default:
          direction = RtpHeaderDirection.sendrecv;
          break;
      }

      var extendedExt = ExtendedRtpHeaderExtension(
        kind: TypeConversion.mediaKindToRtc(remoteExt.kind!),
        uri: remoteExt.uri,
        sendId: matchingLocalExt.preferredId!,
        recvId: remoteExt.preferredId!,
        encrypt: matchingLocalExt.preferredEncrypt ?? false,
        direction: direction,
      );

      extendedRtpCapabilities.headerExtensions.add(extendedExt);
    }

    return extendedRtpCapabilities;
  }

  /// Create RTP parameters for a Consumer for the RTP probator.
  static RtpParameters generateProbatorRtpParameters(RtpParameters videoRtpParameters) {
    // Clone given reference video RTP parameters.
    final validatedParams = validateRtpParameters(videoRtpParameters);

    final rtpParameters = RtpParameters(
      mid: RTP_PROBATOR_MID,
      codecs: [],
      headerExtensions: List.from(validatedParams.headerExtensions),
      encodings: [RtpEncodingParameters(ssrc: RTP_PROBATOR_SSRC)],
      rtcp: RtcpParameters(cname: 'probator', reducedSize: true, mux: true),
    );

    // Add first video codec with modified payload type
    if (validatedParams.codecs.isNotEmpty) {
      final firstCodec = validatedParams.codecs.first;
      rtpParameters.codecs.add(RtpCodecParameters(
        mimeType: firstCodec.mimeType,
        payloadType: RTP_PROBATOR_CODEC_PAYLOAD_TYPE,
        clockRate: firstCodec.clockRate,
        channels: firstCodec.channels,
        parameters: Map.from(firstCodec.parameters),
        rtcpFeedback: List.from(firstCodec.rtcpFeedback),
      ));
    }

    return rtpParameters;
  }

  /// Reduce given codecs by returning an array of codecs "compatible" with the
  /// given capability codec. If no capability codec is given, take the first
  /// one(s).
  static List<RtpCodecParameters> reduceCodecs(
    List<RtpCodecParameters> codecs,
    RtpCodecCapability? capCodec,
  ) {
    List<RtpCodecParameters> filteredCodecs = [];

    // Determine MediaKind from mimeType
    MediaKind getMediaKind(String mimeType) {
      return mimeType.toLowerCase().startsWith('audio/') ? MediaKind.audio : MediaKind.video;
    }

    // If no capability codec is given, take the first one (and RTX if present).
    if (capCodec == null) {
      if (codecs.isNotEmpty) {
        filteredCodecs.add(codecs.first);
        if (codecs.length > 1 && isRtxCodec(RtpCodecCapability(
              mimeType: codecs[1].mimeType,
              clockRate: codecs[1].clockRate,
              kind: getMediaKind(codecs[1].mimeType),
              channels: codecs[1].channels,
              parameters: codecs[1].parameters,
              rtcpFeedback: codecs[1].rtcpFeedback,
            ))) {
          filteredCodecs.add(codecs[1]);
        }
      }
    } else {
      // Look for a compatible set of codecs.
      for (int idx = 0; idx < codecs.length; ++idx) {
        final codecCapability = RtpCodecCapability(
          kind: getMediaKind(codecs[idx].mimeType),
          mimeType: codecs[idx].mimeType,
          clockRate: codecs[idx].clockRate,
          channels: codecs[idx].channels,
          parameters: codecs[idx].parameters,
          rtcpFeedback: codecs[idx].rtcpFeedback,
        );

        if (matchCodecs(aCodec: codecCapability, bCodec: capCodec)) {
          filteredCodecs.add(codecs[idx]);
          if (idx + 1 < codecs.length && isRtxCodec(RtpCodecCapability(
                mimeType: codecs[idx + 1].mimeType,
                clockRate: codecs[idx + 1].clockRate,
                kind: getMediaKind(codecs[idx + 1].mimeType),
                channels: codecs[idx + 1].channels,
                parameters: codecs[idx + 1].parameters,
                rtcpFeedback: codecs[idx + 1].rtcpFeedback,
              ))) {
            filteredCodecs.add(codecs[idx + 1]);
          }
          break;
        }
      }

      if (filteredCodecs.isEmpty) {
        throw Exception('No matching codec found');
      }
    }

    return filteredCodecs;
  }

  /// Generate RTP parameters of the given kind suitable for the remote SDP answer.
  static RtpParameters getSendingRemoteRtpParameters(
    MediaKind kind,
    ExtendedRtpCapabilities extendedRtpCapabilities,
  ) {
    final rtpParameters = RtpParameters(
      mid: null,
      codecs: [],
      headerExtensions: [],
      encodings: [],
      rtcp: RtcpParameters(cname: '', reducedSize: true, mux: true),
    );

    for (ExtendedRtpCodec extendedCodec in extendedRtpCapabilities.codecs) {
      if (extendedCodec.kind != kind) {
        continue;
      }

      final codec = RtpCodecParameters(
        mimeType: extendedCodec.mimeType,
        payloadType: extendedCodec.localPayloadType!,
        clockRate: extendedCodec.clockRate,
        channels: extendedCodec.channels,
        parameters: Map.from(extendedCodec.remoteParameters),
        rtcpFeedback: List.from(extendedCodec.rtcpFeedback),
      );

      rtpParameters.codecs.add(codec);

      // Add RTX codec.
      if (extendedCodec.localRtxPayloadType != null) {
        final rtxCodec = RtpCodecParameters(
          mimeType: '${kind.value}/rtx',
          payloadType: extendedCodec.localRtxPayloadType!,
          clockRate: extendedCodec.clockRate,
          parameters: {'apt': extendedCodec.localPayloadType},
          rtcpFeedback: [],
        );

        rtpParameters.codecs.add(rtxCodec);
      }
    }

    for (ExtendedRtpHeaderExtension extendedExtension in extendedRtpCapabilities.headerExtensions) {
      // Ignore RTP extensions of a different kind and those not valid for sending.
      if ((extendedExtension.kind != null && extendedExtension.kind != kind) ||
          (extendedExtension.direction != RtpHeaderDirection.sendrecv &&
              extendedExtension.direction != RtpHeaderDirection.sendonly)) {
        continue;
      }

      final ext = RtpHeaderExtensionParameters(
        uri: extendedExtension.uri,
        id: extendedExtension.sendId,
        encrypt: extendedExtension.encrypt,
        parameters: {},
      );

      rtpParameters.headerExtensions.add(ext);
    }

    // Reduce codecs' RTCP feedback. Use Transport-CC if available, REMB otherwise.
    final hasTransportCc = rtpParameters.headerExtensions.any((ext) =>
        ext.uri == 'http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01');

    final hasAbsSendTime = rtpParameters.headerExtensions.any((ext) =>
        ext.uri == 'http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time');

    for (RtpCodecParameters codec in rtpParameters.codecs) {
      final filteredFeedback = codec.rtcpFeedback.where((fb) {
        if (hasTransportCc && fb.type == 'goog-remb') return false;
        if (hasAbsSendTime && fb.type == 'transport-cc') return false;
        if (!hasTransportCc && !hasAbsSendTime && (fb.type == 'transport-cc' || fb.type == 'goog-remb')) return false;
        return true;
      }).toList();

      rtpParameters.codecs[rtpParameters.codecs.indexOf(codec)] = RtpCodecParameters(
        mimeType: codec.mimeType,
        payloadType: codec.payloadType,
        clockRate: codec.clockRate,
        channels: codec.channels,
        parameters: Map.from(codec.parameters),
        rtcpFeedback: filteredFeedback,
      );
    }

    return rtpParameters;
  }

  /// Generate RTP capabilities for receiving media based on the given extended
  /// RTP capabilities.
  static RtpCapabilities getRecvRtpCapabilities(ExtendedRtpCapabilities extendedRtpCapabilities) {
    final rtpCapabilities = RtpCapabilities(
      codecs: [],
      headerExtensions: [],
      fecMechanisms: [],
    );

    for (ExtendedRtpCodec extendedCodec in extendedRtpCapabilities.codecs) {
      final codec = RtpCodecCapability(
        kind: TypeConversion.rtcToMediaKind(extendedCodec.kind),
        mimeType: extendedCodec.mimeType,
        preferredPayloadType: extendedCodec.remotePayloadType,
        clockRate: extendedCodec.clockRate,
        channels: extendedCodec.channels,
        parameters: Map.from(extendedCodec.localParameters),
        rtcpFeedback: List.from(extendedCodec.rtcpFeedback),
      );

      rtpCapabilities.codecs.add(codec);

      // Add RTX codec.
      if (extendedCodec.remoteRtxPayloadType != null) {
        final rtxCodec = RtpCodecCapability(
          kind: TypeConversion.rtcToMediaKind(extendedCodec.kind),
          mimeType: '${TypeConversion.rtcMediaTypeToString(extendedCodec.kind)}/rtx',
          preferredPayloadType: extendedCodec.remoteRtxPayloadType,
          clockRate: extendedCodec.clockRate,
          channels: null,
          parameters: {'apt': extendedCodec.remotePayloadType},
          rtcpFeedback: [],
        );

        rtpCapabilities.codecs.add(rtxCodec);
      }
    }

    for (ExtendedRtpHeaderExtension extendedExtension in extendedRtpCapabilities.headerExtensions) {
      // Ignore RTP extensions not valid for receiving.
      if (extendedExtension.direction != RtpHeaderDirection.sendrecv &&
          extendedExtension.direction != RtpHeaderDirection.recvonly) {
        continue;
      }

      final ext = RtpHeaderExtension(
          kind: TypeConversion.stringToMediaKind(TypeConversion.rtcMediaTypeToString(extendedExtension.kind)),
        uri: extendedExtension.uri,
        preferredId: extendedExtension.recvId,
        preferredEncrypt: extendedExtension.encrypt,
        direction: extendedExtension.direction,
      );

      rtpCapabilities.headerExtensions.add(ext);
    }

    return rtpCapabilities;
  }

  /// Generate RTP parameters of the given kind for sending media.
  static RtpParameters getSendingRtpParameters(
    MediaKind kind,
    ExtendedRtpCapabilities extendedRtpCapabilities,
  ) {
    final rtpParameters = RtpParameters(
      mid: null,
      codecs: [],
      headerExtensions: [],
      encodings: [],
      rtcp: RtcpParameters(cname: '', reducedSize: true, mux: true),
    );

    for (ExtendedRtpCodec extendedCodec in extendedRtpCapabilities.codecs) {
      if (extendedCodec.kind != kind) {
        continue;
      }

      final codec = RtpCodecParameters(
        mimeType: extendedCodec.mimeType,
        payloadType: extendedCodec.localPayloadType!,
        clockRate: extendedCodec.clockRate,
        channels: extendedCodec.channels,
        parameters: Map.from(extendedCodec.localParameters),
        rtcpFeedback: List.from(extendedCodec.rtcpFeedback),
      );

      rtpParameters.codecs.add(codec);

      // Add RTX codec.
      if (extendedCodec.localRtxPayloadType != null) {
        final rtxCodec = RtpCodecParameters(
          mimeType: '${kind.value}/rtx',
          payloadType: extendedCodec.localRtxPayloadType!,
          clockRate: extendedCodec.clockRate,
          parameters: {'apt': extendedCodec.localPayloadType},
          rtcpFeedback: [],
        );

        rtpParameters.codecs.add(rtxCodec);
      }
    }

    for (ExtendedRtpHeaderExtension extendedExtension in extendedRtpCapabilities.headerExtensions) {
      // Ignore RTP extensions of a different kind and those not valid for sending.
      if ((extendedExtension.kind != null && extendedExtension.kind != kind) ||
          (extendedExtension.direction != RtpHeaderDirection.sendrecv &&
              extendedExtension.direction != RtpHeaderDirection.sendonly)) {
        continue;
      }

      final ext = RtpHeaderExtensionParameters(
        uri: extendedExtension.uri,
        id: extendedExtension.sendId,
        encrypt: extendedExtension.encrypt,
        parameters: {},
      );

      rtpParameters.headerExtensions.add(ext);
    }

    return rtpParameters;
  }

  /// Whether media can be sent based on the given RTP capabilities.
  static bool canSend(MediaKind kind, ExtendedRtpCapabilities extendedRtpCapabilities) {
    return extendedRtpCapabilities.codecs.any((codec) => codec.kind == kind);
  }

  /// Whether the given RTP parameters can be received with the given RTP
  /// capabilities.
  static bool canReceive(RtpParameters rtpParameters, ExtendedRtpCapabilities extendedRtpCapabilities) {
    final validatedParams = validateRtpParameters(rtpParameters);

    if (validatedParams.codecs.isEmpty) {
      return false;
    }

    final firstMediaCodec = validatedParams.codecs.first;
    return extendedRtpCapabilities.codecs.any((codec) => codec.remotePayloadType == firstMediaCodec.payloadType);
  }
}

class ExtendedRtpCapabilities {
  final List<ExtendedRtpCodec> codecs;
  final List<ExtendedRtpHeaderExtension> headerExtensions;

  ExtendedRtpCapabilities({
    required this.codecs,
    required this.headerExtensions,
  });
}