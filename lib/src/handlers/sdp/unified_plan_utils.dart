// In src/handlers/sdp/unified_plan_utils.dart
import 'package:mediasoup_client_flutter/src/rtp_parameters.dart';
import 'package:mediasoup_client_flutter/src/handlers/sdp/media_section.dart';
import 'package:webrtc_interface/webrtc_interface.dart';
import 'dart:math' show Random;

class UnifiedPlanUtils {
  static List<RtpEncodingParameters> getRtpEncodings(
      MediaObject offerMediaObject) {
    try {
      Set<int> ssrcs = {};

      if (offerMediaObject.ssrcs != null) {
        for (Ssrc line in offerMediaObject.ssrcs!) {
          if (line.id != null) {
            // Add null check
            int? parsedSsrc = int.tryParse(line.id.toString());
            if (parsedSsrc != null) {
              ssrcs.add(parsedSsrc);
            } else {
              ssrcs.add(Random().nextInt(4294967295));
            }
          }
        }
      }

      if (ssrcs.isEmpty) {
        return [
          RtpEncodingParameters(
              ssrc: Random().nextInt(4294967295), maxBitrate: 5000000)
        ];
      }

      Map<int, int> fidGroups = {};
      if (offerMediaObject.ssrcGroups != null) {
        for (SsrcGroup group in offerMediaObject.ssrcGroups!) {
          if (group.semantics == 'FID' && group.ssrcs.isNotEmpty) {
            if (group.ssrcs.length >= 2) {
              int primarySsrc = group.ssrcs[0];
              int rtxSsrc = group.ssrcs[1];
              fidGroups[primarySsrc] = rtxSsrc;
            }
          }
        }
      }

      List<RtpEncodingParameters> encodings = [];
      for (int ssrc in ssrcs) {
        int? rtxSsrc = fidGroups[ssrc];
        encodings.add(RtpEncodingParameters(
          ssrc: ssrc,
          rtx: rtxSsrc != null ? RtxSsrc(rtxSsrc) : null,
        ));
      }

      return encodings.isEmpty
          ? [
              RtpEncodingParameters(
                  ssrc: Random().nextInt(4294967295), maxBitrate: 5000000)
            ]
          : encodings;
    } catch (e) {
      return [
        RtpEncodingParameters(
            ssrc: Random().nextInt(4294967295), maxBitrate: 5000000)
      ];
    }
  }

  // Add this helper (proven single-layer from MediaSFU)
  static List<RtpEncodingParameters> _getFallbackEncodings() {
    int fallbackSsrc = Random().nextInt(4294967295); // Unique int SSRC
    return [
      RtpEncodingParameters(ssrc: fallbackSsrc, maxBitrate: 5000000)
    ]; // Single layer, no RID
  }

  // NEW: Helper to inject fallback SSRC if encodings empty (call this in media_section.dart or before produce)
  static RtpParameters ensureSsrcInParams(RtpParameters? params) {
    if (params == null) return RtpParameters(encodings: []);

    // Ensure encodings exist and have proper SSRC
    if (params.encodings.isEmpty) {
      int fallbackSsrc = DateTime.now().millisecondsSinceEpoch % 4294967295;
      params.encodings = [RtpEncodingParameters(ssrc: fallbackSsrc)];
    } else {
      // Ensure each encoding has a valid SSRC (not string)
      for (var encoding in params.encodings) {
        if (encoding.ssrc == null) {
          encoding.ssrc = _generateUniqueSsrc();
        } else if (encoding.ssrc is String) {
          // Convert string SSRC to int
          encoding.ssrc =
              int.tryParse(encoding.ssrc as String) ?? _generateUniqueSsrc();
        }
      }
    }
    return params;
  }

  static int _generateUniqueSsrc() {
    return (DateTime.now().millisecondsSinceEpoch + Random().nextInt(1000000)) %
        4294967295;
  }

  static List<RtpCodecCapability> matchCodecs(
    List<RtpCodecCapability> codecs,
    List<RtpCodecCapability> remoteCodecs,
  ) {
    List<RtpCodecCapability> matchedCodecs = [];

    for (RtpCodecCapability codec in codecs) {
      for (RtpCodecCapability remoteCodec in remoteCodecs) {
        if (codec.mimeType == remoteCodec.mimeType &&
            codec.clockRate == remoteCodec.clockRate &&
            codec.channels == remoteCodec.channels) {
          matchedCodecs.add(remoteCodec);
          break;
        }
      }
    }

    return matchedCodecs;
  }

  static RtpCodecCapability? getCodecCapability(
    List<RtpCodecCapability> codecs,
    String mimeType,
    int clockRate,
    int? channels,
  ) {
    for (RtpCodecCapability codec in codecs) {
      if (codec.mimeType == mimeType &&
          codec.clockRate == clockRate &&
          codec.channels == channels) {
        return codec;
      }
    }
    return null;
  }

  static void addLegacySimulcast(
    MediaObject offerMediaObject,
    int spatialLayers,
    String streamId,
    String trackId,
  ) {
    // Legacy simulcast implementation
    // This method is called when legacy simulcast is needed
    // The actual implementation would depend on the specific requirements
    // For now, this is a placeholder that satisfies the method signature
  }
}
