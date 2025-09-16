import 'package:mediasoup_client_flutter/src/rtp_parameters.dart';
import 'package:mediasoup_client_flutter/src/handlers/sdp/media_section.dart';
import 'package:webrtc_interface/webrtc_interface.dart';
import 'dart:collection';
import 'dart:math' as math;

// Helper function to safely extract values that might be wrapped in IdentityMap
// 🚨 CRITICAL FIX: Enhanced IdentityMap handling for all cases
dynamic _safeExtractValue(dynamic value) {
  if (value == null) {
    return null;
  }

  if (value is Map) {
    // Handle IdentityMap<String, dynamic> case
    print(
        'DEBUG: _safeExtractValue: Processing IdentityMap with keys: ${value.keys.toList()}');
    print(
        'DEBUG: _safeExtractValue: Processing IdentityMap with values: ${value.values.toList()}');

    if (value.isEmpty) {
      return null;
    }

    // Try multiple approaches to extract meaningful value
    List<dynamic> candidateValues = [];

    // Approach 1: Use values directly
    candidateValues.addAll(value.values);

    // Approach 2: Check if values are also Maps (nested IdentityMap)
    for (dynamic val in value.values) {
      if (val is Map && val.isNotEmpty) {
        candidateValues.addAll(val.values);
      } else if (val is int) {
        candidateValues.add(val);
      } else if (val is String) {
        int? parsed = int.tryParse(val);
        if (parsed != null)
          candidateValues.add(parsed);
        else
          candidateValues.add(val);
      }
    }

    // Approach 3: Check if keys contain meaningful values
    for (dynamic key in value.keys) {
      if (key is String) {
        int? parsed = int.tryParse(key);
        if (parsed != null)
          candidateValues.add(parsed);
        else
          candidateValues.add(key);
      } else if (key is int) {
        candidateValues.add(key);
      }
    }

    // Process candidate values and return the first meaningful one
    for (dynamic candidate in candidateValues) {
      if (candidate != null) {
        if (candidate is Map) {
          // Nested map, recurse
          dynamic nested = _safeExtractValue(candidate);
          if (nested != null) return nested;
        } else {
          return candidate;
        }
      }
    }

    // If no meaningful value found, return the first value
    return value.values.first;
  }

  return value;
}

class UnifiedPlanUtils {
  static List<RtpEncodingParameters> getRtpEncodings(
    MediaObject offerMediaObject,
  ) {
    try {
      print(
        'DEBUG: getRtpEncodings: Starting with ssrcs=${offerMediaObject.ssrcs?.length ?? 0}',
      );

      Set<int> usedSsrcs = {}; // Track used SSRCs to prevent duplicates
      Map<int, int> fidGroups = {};
      List<RtpEncodingParameters> encodings = [];

      // First pass: collect all SSRCs and handle duplicates
      if (offerMediaObject.ssrcs != null) {
        for (Ssrc line in offerMediaObject.ssrcs!) {
          if (line.id == null) {
            print('DEBUG: getRtpEncodings: Skipping null SSRC line: $line');
            continue;
          }

          // 🚨 CRITICAL FIX: Enhanced IdentityMap handling for line.id
          dynamic idValue = line.id;
          int? parsedSsrc;

          if (idValue is Map) {
            // Handle IdentityMap<String, dynamic> case
            print(
                'DEBUG: getRtpEncodings: Found IdentityMap line.id: $idValue');
            print(
                'DEBUG: getRtpEncodings: IdentityMap keys: ${idValue.keys.toList()}');
            print(
                'DEBUG: getRtpEncodings: IdentityMap values: ${idValue.values.toList()}');

            if (idValue.isNotEmpty) {
              // Try multiple approaches to extract SSRC
              List<dynamic> candidateValues = [];

              // Approach 1: Use values directly
              candidateValues.addAll(idValue.values);

              // Approach 2: Check if values are also Maps (nested IdentityMap)
              for (dynamic value in idValue.values) {
                if (value is Map && value.isNotEmpty) {
                  candidateValues.addAll(value.values);
                } else if (value is int) {
                  candidateValues.add(value);
                } else if (value is String) {
                  int? parsed = int.tryParse(value);
                  if (parsed != null) candidateValues.add(parsed);
                }
              }

              // Approach 3: Check if keys contain numeric values
              for (dynamic key in idValue.keys) {
                if (key is String) {
                  int? parsed = int.tryParse(key);
                  if (parsed != null) candidateValues.add(parsed);
                } else if (key is int) {
                  candidateValues.add(key);
                }
              }

              // Process candidate values and find valid SSRC
              for (dynamic candidate in candidateValues) {
                if (candidate is int && candidate > 0) {
                  parsedSsrc = candidate;
                  print(
                      'DEBUG: getRtpEncodings: Extracted SSRC from IdentityMap: $parsedSsrc');
                  break;
                } else if (candidate is String) {
                  int? parsed = int.tryParse(candidate);
                  if (parsed != null && parsed > 0) {
                    parsedSsrc = parsed;
                    print(
                        'DEBUG: getRtpEncodings: Parsed SSRC from IdentityMap string: $parsedSsrc');
                    break;
                  }
                }
              }
            }
          } else if (idValue is String) {
            parsedSsrc = int.tryParse(idValue);
          } else if (idValue is int) {
            parsedSsrc = idValue;
          }

          if (parsedSsrc != null) {
            if (!usedSsrcs.contains(parsedSsrc)) {
              usedSsrcs.add(parsedSsrc);
              print('DEBUG: getRtpEncodings: Added SSRC: $parsedSsrc');
            } else {
              print(
                  'DEBUG: getRtpEncodings: Skipping duplicate SSRC: $parsedSsrc');
            }
          } else {
            print(
                'DEBUG: getRtpEncodings: Failed to parse SSRC from: $idValue');
          }
        }
      }

      // Convert set to list for further processing
      List<int> ssrcs = usedSsrcs.toList();

      if (ssrcs.isEmpty) {
        print('DEBUG: getRtpEncodings: No valid SSRCs found, using fallback');
        return _getFallbackEncodings();
      }

      // Process SSRC groups for RTX mapping with enhanced IdentityMap handling
      if (offerMediaObject.ssrcGroups != null) {
        for (SsrcGroup group in offerMediaObject.ssrcGroups!) {
          if (group.semantics == 'FID' && group.ssrcs != null) {
            List<int> parsedSsrcs = [];
            dynamic ssrcValue = group.ssrcs;

            print(
              'DEBUG: getRtpEncodings: Processing SSRC group with ssrcValue type: ${ssrcValue.runtimeType}, value: $ssrcValue',
            );

            // 🚨 CRITICAL FIX: Enhanced IdentityMap handling for SSRC groups
            if (ssrcValue is Map) {
              print(
                  'DEBUG: getRtpEncodings: Processing IdentityMap SSRC group with keys: ${ssrcValue.keys.toList()}');
              print(
                  'DEBUG: getRtpEncodings: Processing IdentityMap SSRC group with values: ${ssrcValue.values.toList()}');

              // Try multiple approaches to extract SSRC values from IdentityMap
              List<dynamic> candidateValues = [];

              // Approach 1: Use values directly
              candidateValues.addAll(ssrcValue.values);

              // Approach 2: Check if values are also Maps (nested IdentityMap)
              for (dynamic value in ssrcValue.values) {
                if (value is Map && value.isNotEmpty) {
                  candidateValues.addAll(value.values);
                } else if (value is int) {
                  candidateValues.add(value);
                } else if (value is String) {
                  int? parsed = int.tryParse(value);
                  if (parsed != null) candidateValues.add(parsed);
                }
              }

              // Approach 3: Check if keys contain numeric values
              for (dynamic key in ssrcValue.keys) {
                if (key is String) {
                  int? parsed = int.tryParse(key);
                  if (parsed != null) candidateValues.add(parsed);
                } else if (key is int) {
                  candidateValues.add(key);
                }
              }

              // Process candidate values and find valid SSRCs
              for (dynamic candidate in candidateValues) {
                if (candidate is int && candidate > 0) {
                  parsedSsrcs.add(candidate);
                  print(
                      'DEBUG: getRtpEncodings: Added SSRC from IdentityMap group: $candidate');
                } else if (candidate is String) {
                  int? parsed = int.tryParse(candidate);
                  if (parsed != null && parsed > 0) {
                    parsedSsrcs.add(parsed);
                    print(
                        'DEBUG: getRtpEncodings: Parsed SSRC from IdentityMap group string: $parsed');
                  }
                }
              }
            } else if (ssrcValue is String) {
              // 🚨 CRITICAL FIX: Use _safeExtractValue for IdentityMap handling
              String ssrcStr = _safeExtractValue(ssrcValue)?.toString() ?? '';
              parsedSsrcs = ssrcStr
                  .split(' ')
                  .map((s) => int.tryParse(s))
                  .where((s) => s != null)
                  .cast<int>()
                  .toList();
            } else if (ssrcValue is List) {
              // 🚨 CRITICAL FIX: Use _safeExtractValue for IdentityMap handling
              parsedSsrcs = ssrcValue
                  .map((s) {
                    dynamic value = _safeExtractValue(s);
                    return value != null
                        ? int.tryParse(value.toString())
                        : null;
                  })
                  .where((s) => s != null)
                  .cast<int>()
                  .toList();
            }

            if (parsedSsrcs.length >= 2) {
              int primarySsrc = parsedSsrcs[0];
              int rtxSsrc = parsedSsrcs[1];
              fidGroups[primarySsrc] = rtxSsrc;
              print(
                'DEBUG: getRtpEncodings: Mapped SSRC $primarySsrc to RTX $rtxSsrc',
              );
            } else {
              print(
                'DEBUG: getRtpEncodings: Skipping invalid SSRC group: $parsedSsrcs',
              );
            }
          }
        }
      }

      // Create final encodings with RTX mappings
      for (int ssrc in ssrcs) {
        int? rtxSsrc = fidGroups[ssrc];
        encodings.add(
          RtpEncodingParameters(
            ssrc: ssrc,
            rtx: rtxSsrc != null ? RtxSsrc(rtxSsrc) : null,
            active: true,
          ),
        );
        print(
          'DEBUG: getRtpEncodings: Added encoding: ssrc=$ssrc, rtxSsrc=$rtxSsrc',
        );
      }

      // Ensure we have at least one encoding
      if (encodings.isEmpty) {
        print('DEBUG: getRtpEncodings: No encodings found, creating default');
        encodings.add(RtpEncodingParameters());
      }

      print(
        'DEBUG: getRtpEncodings: Final encodings=${encodings.map((e) => 'ssrc=${e.ssrc}, rtx=${e.rtx?.ssrc}').join(', ')}',
      );
      return encodings;
    } catch (e) {
      print('DEBUG: getRtpEncodings: Error: $e');
      return _getFallbackEncodings();
    }
  }

  static RtpParameters ensureSsrcInParams(RtpParameters rtpParameters) {
    print(
      'DEBUG: ensureSsrcInParams: Input encodings=${rtpParameters.encodings.map((e) => 'ssrc=${e.ssrc}').join(', ')}',
    );
    try {
      print(
        'DEBUG: ensureSsrcInParams: Starting with encodings=${rtpParameters.encodings.length}',
      );
      // Create a new list of encodings with SSRCs assigned
      List<RtpEncodingParameters> updatedEncodings = [];
      for (int i = 0; i < rtpParameters.encodings.length; i++) {
        RtpEncodingParameters encoding = rtpParameters.encodings[i];
        int? ssrc = encoding.ssrc;
        if (ssrc == null) {
          ssrc = _generateUniqueSsrc();
          print(
            'DEBUG: ensureSsrcInParams: Assigned SSRC=$ssrc to encoding $i',
          );
        }
        RtxSsrc? rtx = encoding.rtx;
        if (rtx?.ssrc == null && encoding.rtx != null) {
          int newRtxSsrc = _generateUniqueSsrc();
          rtx = RtxSsrc(newRtxSsrc);
          print(
            'DEBUG: ensureSsrcInParams: Assigned RTX SSRC=$newRtxSsrc to encoding $i',
          );
        }
        updatedEncodings.add(
          RtpEncodingParameters(
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
          ),
        );
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
        'DEBUG: ensureSsrcInParams: Updated encodings=${updatedEncodings.map((e) => 'ssrc=${e.ssrc}, rtx=${e.rtx?.ssrc ?? null}')}]',
      );
      return updatedParams;
    } catch (e) {
      print('DEBUG: ensureSsrcInParams: Error: $e, returning original');
      return rtpParameters;
    }
  }

  static List<RtpEncodingParameters> _getFallbackEncodings() {
    int ssrc = _generateUniqueSsrc();
    print('DEBUG: _getFallbackEncodings: Generated fallback SSRC=$ssrc');
    return [RtpEncodingParameters(ssrc: ssrc)];
  }

  static void addLegacySimulcast(
    MediaObject offerMediaObject,
    int numStreams,
    String? streamId,
    String? trackId,
  ) {
    print(
      'DEBUG: addLegacySimulcast: Starting with streamId=$streamId, trackId=$trackId, numStreams=$numStreams',
    );
    int? firstSsrc;

    offerMediaObject.ssrcs ??= [];
    for (Ssrc line in offerMediaObject.ssrcs!) {
      if (line.attribute != 'msid' || (line.value?.isEmpty ?? true)) {
        print(
          'DEBUG: addLegacySimulcast: Skipping invalid msid line: attribute=${line.attribute}, value=${line.value}',
        );
        continue;
      }

      // 🚨 CRITICAL FIX: Use _safeExtractValue for IdentityMap handling
      String valueStr = _safeExtractValue(line.value)?.toString() ?? '';
      print('DEBUG: addLegacySimulcast: Forced value to string: $valueStr');

      final List<String> tokens = valueStr.split(' ');
      final String msidStreamId = tokens.isNotEmpty ? tokens[0] : '';
      final String msidTrackId = tokens.length > 1 ? tokens[1] : '';

      if (msidStreamId == streamId && msidTrackId == trackId) {
        // 🚨 CRITICAL FIX: Use _safeExtractValue for IdentityMap handling
        firstSsrc = int.tryParse(_safeExtractValue(line.id)?.toString() ?? '0');
        print(
          'DEBUG: addLegacySimulcast: Found msid match: SSRC=${line.id}, streamId=$streamId, trackId=$trackId',
        );
        break;
      }
    }

    if (firstSsrc == null) {
      print(
        'DEBUG: addLegacySimulcast: No matching SSRC found, using fallback',
      );
      firstSsrc = _generateUniqueSsrc();
      offerMediaObject.ssrcs!.add(
        Ssrc(
          id: firstSsrc,
          attribute: 'msid',
          value: '${streamId ?? '-'} ${trackId ?? '-'}',
        ),
      );
      offerMediaObject.ssrcs!.add(
        Ssrc(
          id: firstSsrc,
          attribute: 'cname',
          value: 'cname-${math.Random().nextInt(1000000)}',
        ),
      );
    }

    if (numStreams > 1) {
      offerMediaObject.ssrcGroups ??= [];
      List<int> additionalSsrcs = [];
      for (int i = 1; i < numStreams; i++) {
        int newSsrc = _generateUniqueSsrc();
        additionalSsrcs.add(newSsrc);
        offerMediaObject.ssrcs!.add(
          Ssrc(
            id: newSsrc,
            attribute: 'msid',
            value: '${streamId ?? '-'} ${trackId ?? '-'}',
          ),
        );
        offerMediaObject.ssrcs!.add(
          Ssrc(
            id: newSsrc,
            attribute: 'cname',
            value: 'cname-${math.Random().nextInt(1000000)}',
          ),
        );
      }
      print(
        'DEBUG: addLegacySimulcast: Adding SIM group with ssrcs=[${[
          firstSsrc,
          ...additionalSsrcs
        ].join(', ')}]',
      );
      offerMediaObject.ssrcGroups!.add(
        SsrcGroup(semantics: 'SIM', ssrcs: [firstSsrc, ...additionalSsrcs]),
      );
    }
  }
}

int _generateUniqueSsrc() {
  return math.Random().nextInt(4294967295);
}
