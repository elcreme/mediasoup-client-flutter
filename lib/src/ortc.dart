import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mediasoup_client_flutter/src/common/logger.dart';
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
    final logger = Logger('Ortc:matchCodecs');
    String aMimeType = aCodec.mimeType.toLowerCase();
    String bMimeType = bCodec.mimeType.toLowerCase();

    if (aMimeType != bMimeType) {
      logger.debug('MimeType mismatch: $aMimeType != $bMimeType');
      return false;
    }

    if (aCodec.clockRate != bCodec.clockRate) {
      logger.debug('clockRate mismatch: ${aCodec.clockRate} != ${bCodec.clockRate}');
      return false;
    }

    // Only compare channels for audio codecs
    if (aMimeType.startsWith('audio/') && aCodec.channels != bCodec.channels) {
      logger.debug('channels mismatch for audio codec: ${aCodec.channels} != ${bCodec.channels}');
      return false;
    }

    // Per codec special checks.
    switch (aMimeType) {
      case 'video/h264':
        {
          var aPacketizationMode = aCodec.parameters['packetization-mode'] ?? 0;
          var bPacketizationMode = bCodec.parameters['packetization-mode'] ?? 0;

          if (aPacketizationMode != bPacketizationMode) {
            logger.debug('H264 packetization-mode mismatch: $aPacketizationMode != $bPacketizationMode');
            return false;
          }

          // If strict matching check profile-level-id.
          if (strict) {
            final isSame = H264Utils.isSameProfile(aCodec.parameters, bCodec.parameters);
            if (!isSame) {
              logger.debug('H264 profile not same. aParams: ${aCodec.parameters}, bParams: ${bCodec.parameters}');
              return false;
            }

            String? selectedProfileLevelId;

            try {
              selectedProfileLevelId = H264Utils.generateProfileLevelIdForAnswer(
                local_supported_params: aCodec.parameters,
                remote_offered_params: bCodec.parameters,
              );
              logger.debug('H264 generateProfileLevelIdForAnswer succeeded: $selectedProfileLevelId');
            } catch (error) {
              logger.error('H264 generateProfileLevelIdForAnswer failed: $error');
              return false;
            }

            if (modify) {
              aCodec.parameters['profile-level-id'] = selectedProfileLevelId;
              logger.debug('Modified aCodec profile-level-id to $selectedProfileLevelId');
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
              logger.debug('VP9 profile-id mismatch: $aProfileId != $bProfileId');
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
    final logger = Logger('Ortc:getExtendedRtpCapabilities');
    logger.debug('Starting getExtendedRtpCapabilities with local codecs: ${localCaps.codecs.length}, remote codecs: ${remoteCaps.codecs.length}');

    // Log local and remote codecs for debugging
    logger.debug('Local codecs: ${localCaps.codecs.map((c) => c.mimeType).join(', ')}');
    logger.debug('Remote codecs: ${remoteCaps.codecs.map((c) => c.mimeType).join(', ')}');

    final extendedRtpCapabilities = ExtendedRtpCapabilities(
      codecs: [],
      headerExtensions: [],
    );

    // Match media codecs and keep the order preferred by remoteCaps.
    for (RtpCodecCapability localCodec in localCaps.codecs) {
      logger.debug('Trying to match local codec: ${localCodec.mimeType} (clockRate: ${localCodec.clockRate}, channels: ${localCodec.channels})');

      final matchingRemoteCodec = remoteCaps.codecs.firstWhereOrNull(
        (remoteCodec) {
          final match = matchCodecs(aCodec: localCodec, bCodec: remoteCodec, strict: true, modify: true);
          if (match) {
            logger.debug('Matched with remote codec: ${remoteCodec.mimeType}');
          } else {
            logger.debug('No match with remote codec: ${remoteCodec.mimeType} (clockRate mismatch or other)');
          }
          return match;
        },
      );

      if (matchingRemoteCodec == null) {
        logger.debug('No match for local codec: ${localCodec.mimeType}');
        continue;
      }

      final extendedCodec = ExtendedRtpCodec(
        kind: TypeConversion.mediaKindToRtc(localCodec.kind),
        mimeType: matchingRemoteCodec.mimeType,
        clockRate: matchingRemoteCodec.clockRate,
        channels: matchingRemoteCodec.channels,
        localPayloadType: localCodec.preferredPayloadType,
        localRtxPayloadType: null,
        remotePayloadType: matchingRemoteCodec.preferredPayloadType,
        remoteRtxPayloadType: null,
        localParameters: Map.from(localCodec.parameters),
        remoteParameters: Map.from(matchingRemoteCodec.parameters),
        rtcpFeedback: reduceRtcpFeedback(localCodec, matchingRemoteCodec),
      );

      extendedRtpCapabilities.codecs.add(extendedCodec);
      logger.debug('Extended codec added: ${extendedCodec.mimeType} (localPT: ${extendedCodec.localPayloadType}, remotePT: ${extendedCodec.remotePayloadType})');
    }

    // Match RTX codecs.
    for (ExtendedRtpCodec extendedCodec in extendedRtpCapabilities.codecs) {
      final matchingLocalRtxCodec = localCaps.codecs.firstWhereOrNull(
        (localCodec) => isRtxCodec(localCodec) && localCodec.parameters['apt'] == extendedCodec.localPayloadType,
      );

      final matchingRemoteRtxCodec = remoteCaps.codecs.firstWhereOrNull(
        (remoteCodec) => isRtxCodec(remoteCodec) && remoteCodec.parameters['apt'] == extendedCodec.remotePayloadType,
      );

      if (matchingLocalRtxCodec != null && matchingRemoteRtxCodec != null) {
        extendedCodec.localRtxPayloadType = matchingLocalRtxCodec.preferredPayloadType;
        extendedCodec.remoteRtxPayloadType = matchingRemoteRtxCodec.preferredPayloadType;
        logger.debug('Added RTX for codec ${extendedCodec.mimeType}: localRtxPT=${extendedCodec.localRtxPayloadType}, remoteRtxPT=${extendedCodec.remoteRtxPayloadType}');
      } else {
        logger.warn('No RTX match for codec: ${extendedCodec.mimeType}');
      }
    }

    // Match header extensions.
    for (RtpHeaderExtension localExt in localCaps.headerExtensions) {
      final matchingRemoteExt = remoteCaps.headerExtensions.firstWhereOrNull(
        (remoteExt) => matchHeaderExtensions(localExt, remoteExt),
      );

      if (matchingRemoteExt == null) {
        logger.debug('No match for local header extension: ${localExt.uri}');
        continue;
      }

      var direction = RtpHeaderDirection.sendrecv;
      switch (matchingRemoteExt.direction) {
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
        kind: localExt.kind != null ? TypeConversion.mediaKindToRtc(localExt.kind!) : RTCRtpMediaType.RTCRtpMediaTypeAudio,
        uri: localExt.uri,
        sendId: localExt.preferredId!,
        recvId: matchingRemoteExt.preferredId!,
        encrypt: localExt.preferredEncrypt ?? false,
        direction: direction,
      );

      extendedRtpCapabilities.headerExtensions.add(extendedExt);
      logger.debug('Extended header extension added: ${extendedExt.uri} (sendId: ${extendedExt.sendId}, recvId: ${extendedExt.recvId})');
    }

    // Log final extended capabilities
    logger.debug('Final extended codecs count: ${extendedRtpCapabilities.codecs.length}');
    if (extendedRtpCapabilities.codecs.isEmpty) {
      logger.error('No extended codecs generated - check local/remote capabilities mismatch');
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
    final logger = Logger('Ortc:getSendingRemoteRtpParameters');
    logger.debug('Starting getSendingRemoteRtpParameters for kind: ${kind.value}');

    final rtpParameters = RtpParameters(
      mid: null,
      codecs: [],
      headerExtensions: [],
      encodings: [],
      rtcp: RtcpParameters(cname: '', reducedSize: true, mux: true),
    );

    for (ExtendedRtpCodec extendedCodec in extendedRtpCapabilities.codecs) {
      if (extendedCodec.kind != TypeConversion.mediaKindToRtc(kind)) {
        logger.debug('Skipping codec with mismatched kind: ${extendedCodec.mimeType} (expected: ${kind.value})');
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
      logger.debug('Added codec: ${codec.mimeType} (payloadType: ${codec.payloadType})');

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
        logger.debug('Added RTX codec for ${codec.mimeType} (payloadType: ${rtxCodec.payloadType})');
      }
    }

    for (ExtendedRtpHeaderExtension extendedExtension in extendedRtpCapabilities.headerExtensions) {
      // Ignore RTP extensions of a different kind and those not valid for sending.
      if ((extendedExtension.kind != null && extendedExtension.kind != TypeConversion.mediaKindToRtc(kind)) ||
          (extendedExtension.direction != RtpHeaderDirection.sendrecv &&
              extendedExtension.direction != RtpHeaderDirection.sendonly)) {
        logger.debug('Skipping header extension: ${extendedExtension.uri} (mismatched kind/direction)');
        continue;
      }

      final ext = RtpHeaderExtensionParameters(
        uri: extendedExtension.uri,
        id: extendedExtension.sendId,
        encrypt: extendedExtension.encrypt,
        parameters: {},
      );

      rtpParameters.headerExtensions.add(ext);
      logger.debug('Added header extension: ${ext.uri} (id: ${ext.id})');
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

    // Log final parameters
    logger.debug('Final RTP parameters codecs count: ${rtpParameters.codecs.length}');
    if (rtpParameters.codecs.isEmpty) {
      logger.error('No codecs generated for remote parameters - this may cause issues');
    }

    return rtpParameters;
  }

  /// Generate RTP capabilities for receiving media based on the given extended
  /// RTP capabilities.
  static RtpCapabilities getRecvRtpCapabilities(ExtendedRtpCapabilities extendedRtpCapabilities) {
    final logger = Logger('Ortc:getRecvRtpCapabilities');
    logger.debug('Starting getRecvRtpCapabilities with codecs: ${extendedRtpCapabilities.codecs.length}');

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
      logger.debug('Added codec: ${codec.mimeType} (payloadType: ${codec.preferredPayloadType})');

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
        logger.debug('Added RTX codec for ${codec.mimeType} (payloadType: ${rtxCodec.preferredPayloadType})');
      }
    }

    for (ExtendedRtpHeaderExtension extendedExtension in extendedRtpCapabilities.headerExtensions) {
      // Ignore RTP extensions not valid for receiving.
      if (extendedExtension.direction != RtpHeaderDirection.sendrecv &&
          extendedExtension.direction != RtpHeaderDirection.recvonly) {
        logger.debug('Skipping header extension: ${extendedExtension.uri} (not valid for receiving)');
        continue;
      }

      final ext = RtpHeaderExtension(
        kind: TypeConversion.rtcToMediaKind(extendedExtension.kind),
        uri: extendedExtension.uri,
        preferredId: extendedExtension.recvId,
        preferredEncrypt: extendedExtension.encrypt,
        direction: extendedExtension.direction,
      );

      rtpCapabilities.headerExtensions.add(ext);
      logger.debug('Added header extension: ${ext.uri} (id: ${ext.preferredId})');
    }

    logger.debug('Final receive codecs count: ${rtpCapabilities.codecs.length}');
    return rtpCapabilities;
  }

  /// Generate RTP parameters of the given kind for sending media.
  static RtpParameters getSendingRtpParameters(
    MediaKind kind,
    ExtendedRtpCapabilities extendedRtpCapabilities,
  ) {
    final logger = Logger('Ortc:getSendingRtpParameters');
    logger.debug('Starting getSendingRtpParameters for kind: ${kind.value}');

    final rtpParameters = RtpParameters(
      mid: null,
      codecs: [],
      headerExtensions: [],
      encodings: [],
      rtcp: RtcpParameters(cname: '', reducedSize: true, mux: true),
    );

    // Log incoming extended capabilities
    logger.debug('Extended RTP capabilities codecs count: ${extendedRtpCapabilities.codecs.length}');

    for (ExtendedRtpCodec extendedCodec in extendedRtpCapabilities.codecs) {
      if (extendedCodec.kind != TypeConversion.mediaKindToRtc(kind)) {
        logger.debug('Skipping codec with mismatched kind: ${extendedCodec.mimeType} (expected: ${kind.value})');
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
      logger.debug('Added codec: ${codec.mimeType} (payloadType: ${codec.payloadType})');

      // Add RTX codec if available.
      if (extendedCodec.localRtxPayloadType != null) {
        final rtxCodec = RtpCodecParameters(
          mimeType: '${kind.value}/rtx',
          payloadType: extendedCodec.localRtxPayloadType!,
          clockRate: extendedCodec.clockRate,
          parameters: {'apt': extendedCodec.localPayloadType},
          rtcpFeedback: [],
        );

        rtpParameters.codecs.add(rtxCodec);
        logger.debug('Added RTX codec for ${codec.mimeType} (payloadType: ${rtxCodec.payloadType})');
      }
    }

    // Fallback: If no codecs were added, add defaults (proven fallback from Versatica patterns)
    if (rtpParameters.codecs.isEmpty) {
      logger.warn('No codecs found in extended capabilities - adding fallbacks for ${kind.value}');
      if (kind == MediaKind.audio) {
        // Default audio: Opus
        rtpParameters.codecs.add(RtpCodecParameters(
          mimeType: 'audio/opus',
          payloadType: 111,
          clockRate: 48000,
          channels: 2,
          parameters: {'minptime': 10, 'useinbandfec': 1},
          rtcpFeedback: [],
        ));
        logger.debug('Added fallback audio codec: audio/opus');
      } else if (kind == MediaKind.video) {
        // Default video: H264 (with baseline profile for broad compatibility)
        rtpParameters.codecs.add(RtpCodecParameters(
          mimeType: 'video/H264',
          payloadType: 96,
          clockRate: 90000,
          parameters: {'packetization-mode': 1, 'profile-level-id': '42e01f', 'level-asymmetry-allowed': 1},
          rtcpFeedback: [
            RtcpFeedback(type: 'nack'),
            RtcpFeedback(type: 'nack', parameter: 'pli'),
            RtcpFeedback(type: 'goog-remb'),
          ],
        ));
        // Add RTX for video
        rtpParameters.codecs.add(RtpCodecParameters(
          mimeType: 'video/rtx',
          payloadType: 97,
          clockRate: 90000,
          parameters: {'apt': 96},
          rtcpFeedback: [],
        ));
        logger.debug('Added fallback video codec: video/H264 with RTX');
      }
    }

    for (ExtendedRtpHeaderExtension extendedExtension in extendedRtpCapabilities.headerExtensions) {
      // Ignore RTP extensions of a different kind and those not valid for sending.
      if ((extendedExtension.kind != null && extendedExtension.kind != TypeConversion.mediaKindToRtc(kind)) ||
          (extendedExtension.direction != RtpHeaderDirection.sendrecv &&
              extendedExtension.direction != RtpHeaderDirection.sendonly)) {
        logger.debug('Skipping header extension: ${extendedExtension.uri} (mismatched kind/direction)');
        continue;
      }

      final ext = RtpHeaderExtensionParameters(
        uri: extendedExtension.uri,
        id: extendedExtension.sendId,
        encrypt: extendedExtension.encrypt,
        parameters: {},
      );

      rtpParameters.headerExtensions.add(ext);
      logger.debug('Added header extension: ${ext.uri} (id: ${ext.id})');
    }

    // Log final parameters
    logger.debug('Final RTP parameters codecs count: ${rtpParameters.codecs.length}');
    if (rtpParameters.codecs.isEmpty) {
      logger.error('Failed to generate any codecs - this will cause downstream failures');
    }

    return rtpParameters;
  }

  /// Whether media can be sent based on the given RTP capabilities.
  static bool canSend(MediaKind kind, ExtendedRtpCapabilities extendedRtpCapabilities) {
    final logger = Logger('Ortc:canSend');
    final rtcKind = TypeConversion.mediaKindToRtc(kind);
    final canSendResult = extendedRtpCapabilities.codecs.any((codec) => codec.kind == rtcKind);
    logger.debug('Can send ${kind.value}: $canSendResult (converted rtcKind: $rtcKind)');
    return canSendResult;
  }

  /// Whether the given RTP parameters can be received with the given RTP
  /// capabilities.
  static bool canReceive(RtpParameters rtpParameters, ExtendedRtpCapabilities extendedRtpCapabilities) {
    final logger = Logger('Ortc:canReceive');
    final validatedParams = validateRtpParameters(rtpParameters);

    if (validatedParams.codecs.isEmpty) {
      logger.warn('No codecs in RTP parameters - cannot receive');
      return false;
    }

    final firstMediaCodec = validatedParams.codecs.first;
    final canReceiveResult = extendedRtpCapabilities.codecs.any((codec) => codec.remotePayloadType == firstMediaCodec.payloadType);
    logger.debug('Can receive codec ${firstMediaCodec.mimeType}: $canReceiveResult');
    return canReceiveResult;
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