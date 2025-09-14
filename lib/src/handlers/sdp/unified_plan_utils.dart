import 'package:mediasoup_client_flutter/src/rtp_parameters.dart';
import 'package:mediasoup_client_flutter/src/handlers/sdp/media_section.dart';
import 'package:webrtc_interface/webrtc_interface.dart';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

class UnifiedPlanUtils {
  static List<RtpEncodingParameters> getRtpEncodings(
      MediaObject offerMediaObject) {
    try {
      print(
          'DEBUG: getRtpEncodings: Starting with ssrcs=${offerMediaObject.ssrcs?.length ?? 0}');
      Set<int> ssrcs = {};

      if (offerMediaObject.ssrcs != null) {
        for (Ssrc line in offerMediaObject.ssrcs!) {
          if (line.id == null) {
            print('DEBUG: getRtpEncodings: Skipping null SSRC line: $line');
            continue;
          }
          int? parsedSsrc = int.tryParse(line.id.toString());
          if (parsedSsrc != null) {
            ssrcs.add(parsedSsrc);
            print('DEBUG: getRtpEncodings: Added SSRC: $parsedSsrc');
          } else {
            print('DEBUG: getRtpEncodings: Skipping invalid SSRC: ${line.id}');
          }
        }
      }

      if (ssrcs.isEmpty) {
        print('DEBUG: getRtpEncodings: No valid SSRCs found, using fallback');
        return _getFallbackEncodings();
      }

      Map<int, int> fidGroups = {};
      if (offerMediaObject.ssrcGroups != null) {
        for (SsrcGroup group in offerMediaObject.ssrcGroups!) {
          if (group.semantics == 'FID' && group.ssrcs != null) {
            List<int> parsedSsrcs = [];
            if (group.ssrcs is String) {
              print(
                  'DEBUG: getRtpEncodings: Found string ssrcs: ${group.ssrcs}');
              parsedSsrcs = (group.ssrcs as String)
                  .split(' ')
                  .map((s) => int.tryParse(s))
                  .where((s) => s != null)
                  .cast<int>()
                  .toList();
            } else if (group.ssrcs is List) {
              parsedSsrcs = (group.ssrcs as List)
                  .map((s) => int.tryParse(s.toString()))
                  .where((s) => s != null)
                  .cast<int>()
                  .toList();
            } else {
              print(
                  'DEBUG: getRtpEncodings: Invalid ssrcs type: ${group.ssrcs.runtimeType}');
              continue;
            }

            if (parsedSsrcs.length >= 2) {
              int primarySsrc = parsedSsrcs[0];
              int rtxSsrc = parsedSsrcs[1];
              fidGroups[primarySsrc] = rtxSsrc;
              print(
                  'DEBUG: getRtpEncodings: Mapped SSRC $primarySsrc to RTX $rtxSsrc');
            } else {
              print(
                  'DEBUG: getRtpEncodings: Skipping invalid SSRC group: $parsedSsrcs');
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
        print(
            'DEBUG: getRtpEncodings: Added encoding: ssrc=$ssrc, rtxSsrc=$rtxSsrc');
      }

      print('DEBUG: getRtpEncodings: Final encodings=${encodings.map((e) => 'ssrc=${e.ssrc}, rtx=${e.rtx?.ssrc}').join(', ')}');
      return encodings;
    } catch (e) {
      print('DEBUG: getRtpEncodings: Error: $e');
      return _getFallbackEncodings();
    }
  }

  static RtpParameters ensureSsrcInParams(RtpParameters rtpParameters) {
    print('DEBUG: ensureSsrcInParams: Input encodings=${rtpParameters.encodings.map((e) => 'ssrc=${e.ssrc}').join(', ')}');
    try {
      print(
          'DEBUG: ensureSsrcInParams: Starting with encodings=${rtpParameters.encodings.length}');
      // Create a new list of encodings with SSRCs assigned
      List<RtpEncodingParameters> updatedEncodings = [];
      for (int i = 0; i < rtpParameters.encodings.length; i++) {
        RtpEncodingParameters encoding = rtpParameters.encodings[i];
        int? ssrc = encoding.ssrc;
        if (ssrc == null) {
          ssrc = _generateUniqueSsrc();
          print(
              'DEBUG: ensureSsrcInParams: Assigned SSRC=$ssrc to encoding $i');
        }
        RtxSsrc? rtx = encoding.rtx;
        if (rtx != null && (rtx.ssrc == null || rtx.ssrc == 0)) {
          int newRtxSsrc = _generateUniqueSsrc();
          rtx = RtxSsrc(newRtxSsrc);
          print(
              'DEBUG: ensureSsrcInParams: Assigned RTX SSRC=$newRtxSsrc to encoding $i');
        }
        updatedEncodings.add(RtpEncodingParameters(
          ssrc: ssrc,
          rid: encoding.rid,
          maxBitrate: encoding.maxBitrate,
          maxFramerate: encoding.maxFramerate,
          minBitrate: encoding.minBitrate,
          dtx: encoding.dtx,
          scalabilityMode: encoding.scalabilityMode,
          scaleResolutionDownBy: encoding.scaleResolutionDownBy,
          active: encoding.active,
          rtx: rtx,
        ));
      }

      // Create a new RtpParameters instance with updated encodings
      RtpParameters updatedParams = RtpParameters(
        mid: rtpParameters.mid,
        codecs: List.from(rtpParameters.codecs),
        headerExtensions: List.from(rtpParameters.headerExtensions),
        encodings: updatedEncodings,
        rtcp: rtpParameters.rtcp != null
            ? RtcpParameters(
                cname: rtpParameters.rtcp!.cname ??
                    'default-cname-${math.Random().nextInt(1000000)}',
                reducedSize: rtpParameters.rtcp!.reducedSize,
                mux: rtpParameters.rtcp!.mux,
              )
            : null,
      );

      print(
          'DEBUG: ensureSsrcInParams: Updated encodings=${updatedEncodings.map((e) => 'ssrc=${e.ssrc}, rtx=${e.rtx?.ssrc ?? null}')}]');
      return updatedParams;
    } catch (e) {
      print('DEBUG: ensureSsrcInParams: Error: $e, returning original');
      return rtpParameters;
    }
  }

  static List<RtpEncodingParameters> _getFallbackEncodings() {
    int ssrc = _generateUniqueSsrc();
    print('DEBUG: _getFallbackEncodings: Generated fallback SSRC=$ssrc');
    return [
      RtpEncodingParameters(
        ssrc: ssrc,
      ),
    ];
  }

 static void addLegacySimulcast(MediaObject offerMediaObject, int numStreams, String? streamId, String? trackId) {
  print('DEBUG: addLegacySimulcast: Starting with streamId=$streamId, trackId=$trackId, numStreams=$numStreams');
  int? firstSsrc;

  offerMediaObject.ssrcs ??= [];
  for (Ssrc line in offerMediaObject.ssrcs!) {
    if (line.attribute != 'msid' || (line.value?.isEmpty ?? true)) { // Guard null/isEmpty
      print('DEBUG: addLegacySimulcast: Skipping invalid msid line: attribute=${line.attribute}, value=${line.value}');
      continue;
    }

    final List<String> tokens = line.value!.split(' '); // ! safe after guard
    final String msidStreamId = tokens.isNotEmpty ? tokens[0] : '';
    final String msidTrackId = tokens.length > 1 ? tokens[1] : '';

    if (msidStreamId == streamId && msidTrackId == trackId) {
      firstSsrc = line.id;
      print('DEBUG: addLegacySimulcast: Found msid match: SSRC=${line.id}, streamId=$streamId, trackId=$trackId');
      break;
    }
  }

  if (firstSsrc == null) {
    print('DEBUG: addLegacySimulcast: No matching SSRC found, using fallback SSRC');
    firstSsrc = _generateUniqueSsrc();
    offerMediaObject.ssrcs!.add(Ssrc(
      id: firstSsrc,
      attribute: 'msid',
      value: '${streamId ?? '-'} ${trackId ?? '-'}', // Guard nulls
    ));
    offerMediaObject.ssrcs!.add(Ssrc(
      id: firstSsrc,
      attribute: 'cname',
      value: 'cname-${math.Random().nextInt(1000000)}',
    ));
  }

  if (numStreams > 1) {
    offerMediaObject.ssrcGroups ??= [];
    List<int> additionalSsrcs = [];
    for (int i = 1; i < numStreams; i++) {
      int newSsrc = _generateUniqueSsrc();
      additionalSsrcs.add(newSsrc);
      offerMediaObject.ssrcs!.add(Ssrc(
        id: newSsrc,
        attribute: 'msid',
        value: '${streamId ?? '-'} ${trackId ?? '-'}',
      ));
      offerMediaObject.ssrcs!.add(Ssrc(
        id: newSsrc,
        attribute: 'cname',
        value: 'cname-${math.Random().nextInt(1000000)}',
      ));
    }
    print('DEBUG: addLegacySimulcast: Adding SIM group with ssrcs=[${[firstSsrc, ...additionalSsrcs].join(', ')}]');
    offerMediaObject.ssrcGroups!.add(SsrcGroup(
      semantics: 'SIM',
      ssrcs: [firstSsrc, ...additionalSsrcs],
    ));
  }
}

  static int _generateUniqueSsrc() {
    return math.Random().nextInt(4294967295);
  }
}
