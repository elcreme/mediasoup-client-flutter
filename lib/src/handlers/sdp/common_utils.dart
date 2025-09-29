import 'package:sdp_transform/sdp_transform.dart';
import 'package:mediasoup_client_flutter/src/rtp_parameters.dart';
import 'package:mediasoup_client_flutter/src/handlers/sdp/media_section.dart';
import 'package:mediasoup_client_flutter/src/transport.dart';

class CommonUtils {
 static RtpCapabilities extractRtpCapabilities(Map<String, dynamic> sdpObject) {
    final capabilities = RtpCapabilities(
      codecs: [],
      headerExtensions: [],
      fecMechanisms: [],
    );

    for (final media in sdpObject['media'] ?? []) {
      if (media['type'] != 'audio' && media['type'] != 'video') {
        continue;
      }

      MediaKind kind;
      if (media['type'] == 'audio') {
        kind = MediaKind.audio;
      } else {
        kind = MediaKind.video;
      }

      // Extract codecs from RTP lines
      for (final rtp in media['rtp'] ?? []) {
        final codec = RtpCodecCapability(
          kind: kind,
          mimeType: '${media['type']}/${rtp['codec']}',
          clockRate: rtp['rate'],
          channels: rtp['encoding'] ?? 1,
          parameters: {},
          rtcpFeedback: [],
        );

        // Add FMTP parameters
        for (final fmtp in media['fmtp'] ?? []) {
          if (fmtp['payload'] == rtp['payload']) {
            final config = fmtp['config'] ?? '';
            final params = <String, dynamic>{};
            for (final param in config.split(';')) {
              final parts = param.split('=');
              if (parts.length == 2) {
                params[parts[0].trim()] = parts[1].trim();
              }
            }
            codec.parameters = params;
          }
        }

        // Add RTCP feedback
        for (final fb in media['rtcpFb'] ?? []) {
          if (fb['payload'] == rtp['payload'] || fb['payload'] == '*') {
            codec.rtcpFeedback.add(RtcpFeedback(
              type: fb['type'],
              parameter: fb['subtype'],
            ));
          }
        }

        capabilities.codecs.add(codec);
      }

      // Extract header extensions
      for (final ext in media['ext'] ?? []) {
        capabilities.headerExtensions.add(RtpHeaderExtension(
          uri: ext['uri'],
          preferredId: ext['value'],
          direction: RtpHeaderDirection.sendrecv,
        ));
      }
    }

    return capabilities;
  }

  /// Extract DTLS parameters from SDP object
  static DtlsParameters extractDtlsParameters(Map<String, dynamic> sdpObject) {
    final fingerprints = <DtlsFingerprint>[];
    DtlsRole role = DtlsRole.auto;

    // Get fingerprint from session level
    for (final attr in sdpObject['attributes'] ?? []) {
      if (attr['key'] == 'fingerprint') {
        final parts = (attr['value'] as String).split(' ');
        if (parts.length >= 2) {
          fingerprints.add(DtlsFingerprint(
            algorithm: parts[0],
            value: parts[1],
          ));
        }
      } else if (attr['key'] == 'setup') {
        switch (attr['value']) {
          case 'active':
            role = DtlsRole.client;
            break;
          case 'passive':
            role = DtlsRole.server;
            break;
          case 'actpass':
          default:
            role = DtlsRole.auto;
        }
      }
    }

    // Get fingerprint from media level if not found at session level
    if (fingerprints.isEmpty) {
      for (final media in sdpObject['media'] ?? []) {
        for (final attr in media['attributes'] ?? []) {
          if (attr['key'] == 'fingerprint') {
            final parts = (attr['value'] as String).split(' ');
            if (parts.length >= 2) {
              fingerprints.add(DtlsFingerprint(
                algorithm: parts[0],
                value: parts[1],
              ));
            }
          }
        }
        if (fingerprints.isNotEmpty) break;
      }
    }

    return DtlsParameters(
      role: role,
      fingerprints: fingerprints,
    );
  }
  /// Get CNAME from media object
  static String getCname(Map<String, dynamic> mediaObject) {
    for (final ssrc in mediaObject['ssrcs'] ?? []) {
      if (ssrc['attribute'] == 'cname') {
        return ssrc['value']?.toString() ?? '';
      }
    }
    return 'mediasoup-client-flutter';
  }

   /// Apply codec parameters to answer media object (versatica-style)
   static void applyCodecParameters(
    RtpParameters rtpParameters,
    Map<String, dynamic> answerMediaObject,
  ) {
    for (final codec in rtpParameters.codecs) {
      // Find corresponding RTP entry
      final rtpEntry = (answerMediaObject['rtp'] ?? []).firstWhere(
        (rtp) => rtp['payload'] == codec.payloadType,
        orElse: () => null,
      );

      if (rtpEntry == null) continue;

      // Update FMTP parameters
      if (codec.parameters.isNotEmpty) {
        final fmtpConfig = codec.parameters.entries
            .map((e) => '${e.key}=${e.value}')
            .join(';');

        // Find or create FMTP entry
        var fmtpEntry = (answerMediaObject['fmtp'] ?? []).firstWhere(
          (fmtp) => fmtp['payload'] == codec.payloadType,
          orElse: () => null,
        );

        if (fmtpEntry != null) {
          fmtpEntry['config'] = fmtpConfig;
        } else {
          answerMediaObject['fmtp'] ??= [];
          answerMediaObject['fmtp']!.add({
            'payload': codec.payloadType,
            'config': fmtpConfig,
          });
        }
      }

      // Update RTCP feedback
      if (codec.rtcpFeedback.isNotEmpty) {
        answerMediaObject['rtcpFb'] ??= [];
        
        // Remove existing feedback for this payload type
        answerMediaObject['rtcpFb']!.removeWhere(
          (fb) => fb['payload'] == codec.payloadType,
        );

        // Add new feedback entries
        for (final fb in codec.rtcpFeedback) {
          answerMediaObject['rtcpFb']!.add({
            'payload': codec.payloadType,
            'type': fb.type,
            'subtype': fb.parameter ?? '',
          });
        }
      }
    }
  }
}
