import 'dart:math';
import 'package:sdp_transform/sdp_transform.dart';
import 'package:mediasoup_client_flutter/src/rtp_parameters.dart';
import 'package:mediasoup_client_flutter/src/handlers/sdp/media_section.dart';
import 'package:webrtc_interface/webrtc_interface.dart';
import 'dart:collection';
import 'dart:math' as math;

// Helper function to safely extract values that might be wrapped in IdentityMap
dynamic _safeExtractValue(dynamic value) {
  if (value == null) {
    return null;
  }

  if (value is Map) {
    // Handle IdentityMap<String, dynamic> case
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
  // Track used SSRCs to ensure uniqueness
  static final Set<int> _usedSsrcs = {};
  static final math.Random _random = math.Random();
  
  /// Generates a unique SSRC that hasn't been used before in this session.
  /// Uses a 31-bit random number (positive 32-bit integer).
  static int _generateUniqueSsrc() {
    int attempts = 0;
    const maxAttempts = 10;
    
    while (attempts < maxAttempts) {
      // Generate a 31-bit random number (positive 32-bit integer)
      final ssrc = _random.nextInt(0x7FFFFFFF);
      
      if (!_usedSsrcs.contains(ssrc)) {
        _usedSsrcs.add(ssrc);
        print('DEBUG: Generated new unique SSRC: $ssrc');
        return ssrc;
      }
      
      attempts++;
      if (attempts == maxAttempts ~/ 2) {
        print('WARNING: Having trouble finding a unique SSRC after $attempts attempts');
      }
    }
    
    // Fallback: use timestamp-based SSRC if we can't find a unique random one
    final fallbackSsrc = (DateTime.now().millisecondsSinceEpoch & 0x7FFFFFFF);
    print('WARNING: Using fallback timestamp-based SSRC: $fallbackSsrc');
    _usedSsrcs.add(fallbackSsrc);
    return fallbackSsrc;
  }

  /// Get RTP encodings from SDP media section (exact versatica signature pattern)
  static List<RtpEncodingParameters> getRtpEncodings({
    required Map<String, dynamic> offerMediaObject,
  }) {
    try {
      print('DEBUG: getRtpEncodings: Starting with ssrcs=${offerMediaObject['ssrcs']?.length ?? 0}');

      // Track all unique SSRCs
      final ssrcs = <int>{};
      
      // First pass: collect all SSRCs
      for (final line in offerMediaObject['ssrcs'] ?? []) {
        final ssrcValue = _safeExtractValue(line['id']);
        if (ssrcValue == null) continue;
        
        final ssrcNum = int.tryParse(ssrcValue.toString());
        if (ssrcNum == null) continue;
        
        ssrcs.add(ssrcNum);
      }

      if (ssrcs.isEmpty) {
        throw Exception('No SSRCs found in offer');
      }

      // Map to store SSRC to RTX SSRC mapping
      final ssrcToRtxSsrc = <int, int?>{};

      // First handle FID (RTX) SSRC groups
      for (final group in offerMediaObject['ssrcGroups'] ?? []) {
        if ((group['semantics']?.toString().toLowerCase() ?? '') != 'fid') {
          continue;
        }

        try {
          final ssrcsStr = _safeExtractValue(group['ssrcs'])?.toString()?.trim() ?? '';
          if (ssrcsStr.isEmpty) continue;
          
          final ssrcList = ssrcsStr.split(' ').where((s) => s.isNotEmpty).toList();
          if (ssrcList.length < 2) continue;
          
          final ssrc = int.tryParse(ssrcList[0]!);
          final rtxSsrc = int.tryParse(ssrcList[1]!);
          
          if (ssrc == null || rtxSsrc == null) continue;
          
          // Only add if the primary SSRC exists in our set
          if (ssrcs.contains(ssrc)) {
            // Remove both SSRCs from the set to mark them as handled
            ssrcs.remove(ssrc);
            ssrcs.remove(rtxSsrc);
            
            // Add to the map
            ssrcToRtxSsrc[ssrc] = rtxSsrc;
            print('DEBUG: getRtpEncodings: Mapped SSRC $ssrc -> RTX $rtxSsrc');
          }
        } catch (e) {
          print('WARNING: getRtpEncodings: Error processing FID group: $e');
          continue;
        }
      }

      // Add remaining SSRCs (without RTX)
      for (final ssrc in ssrcs) {
        ssrcToRtxSsrc[ssrc] = null;
      }

      // Create RTP encodings
      final encodings = <RtpEncodingParameters>[];
      
      for (final entry in ssrcToRtxSsrc.entries) {
        final ssrc = entry.key;
        final rtxSsrc = entry.value;
        
        try {
          final encoding = RtpEncodingParameters(
            ssrc: ssrc,
            active: true,
          );
          
          if (rtxSsrc != null) {
            if (rtxSsrc <= 0) {
              print('WARNING: getRtpEncodings: Invalid RTX SSRC: $rtxSsrc');
            } else {
              encoding.rtx = Rtx(ssrc: rtxSsrc);
            }
          }
          
          encodings.add(encoding);
          print('DEBUG: getRtpEncodings: Created encoding: ssrc=$ssrc, rtxSsrc=$rtxSsrc');
        } catch (e) {
          print('ERROR: getRtpEncodings: Error creating encoding for SSRC $ssrc: $e');
          rethrow;
        }
      }

      if (encodings.isEmpty) {
        throw Exception('Failed to create any RTP encodings');
      }

      print('DEBUG: getRtpEncodings: Successfully created ${encodings.length} encodings');
      return encodings;
    } catch (error) {
      print('ERROR: getRtpEncodings failed: $error');
      rethrow;
    }
  }

  /// Add legacy simulcast (exact versatica signature pattern)
  static void addLegacySimulcast({
    required Map<String, dynamic> offerMediaObject,
    required int numStreams,
  }) {
    if (numStreams <= 1) {
      throw ArgumentError('numStreams must be greater than 1');
    }

    // Get the SSRC
    final ssrcMsidLine = (offerMediaObject['ssrcs'] ?? []).firstWhere(
      (line) => line['attribute'] == 'msid',
      orElse: () => {'id': 0, 'attribute': '', 'value': ''}
    );

    if (ssrcMsidLine['id'] == 0 || ssrcMsidLine['value'] == null) {
      throw Exception('a=ssrc line with msid information not found');
    }

    final valueStr = _safeExtractValue(ssrcMsidLine['value'])?.toString() ?? '';
    final tokens = valueStr.split(' ');
    final streamId = tokens.isNotEmpty ? tokens[0] : '';
    final trackId = tokens.length > 1 ? tokens[1] : '';
    
    final firstSsrc = int.tryParse(_safeExtractValue(ssrcMsidLine['id'])?.toString() ?? '0') ?? 0;
    if (firstSsrc == 0) {
      throw Exception('Invalid SSRC value');
    }

    // Get the SSRC for RTX
    int? firstRtxSsrc;
    for (final group in offerMediaObject['ssrcGroups'] ?? []) {
      if ((group['semantics']?.toString().toLowerCase() ?? '') != 'fid') continue;
      
      final ssrcsStr = _safeExtractValue(group['ssrcs'])?.toString() ?? '';
      if (ssrcsStr.isEmpty) continue;
      
      final ssrcs = ssrcsStr.split(' ').where((s) => s.isNotEmpty).toList();
      if (ssrcs.length < 2) continue;
      
      final ssrc = int.tryParse(ssrcs[0]!);
      if (ssrc == firstSsrc) {
        firstRtxSsrc = int.tryParse(ssrcs[1]!);
        break;
      }
    }

    // Get CNAME
    final ssrcCnameLine = (offerMediaObject['ssrcs'] ?? []).firstWhere(
      (line) => line['attribute'] == 'cname',
      orElse: () => {'id': 0, 'attribute': '', 'value': ''}
    );

    if (ssrcCnameLine['value'] == null) {
      throw Exception('a=ssrc line with cname information not found');
    }

    final cname = _safeExtractValue(ssrcCnameLine['value'])?.toString() ?? '';
    
    // Generate SSRCs for simulcast
    final ssrcs = <int>[];
    final rtxSsrcs = <int>[];
    
    for (var i = 0; i < numStreams; i++) {
      ssrcs.add(firstSsrc + i);
      
      if (firstRtxSsrc != null) {
        rtxSsrcs.add(firstRtxSsrc + i);
      }
    }

    // Clear existing SSRC groups and SSRCs
    offerMediaObject['ssrcGroups'] = [];
    offerMediaObject['ssrcs'] = [];

    // Add SIM group
    offerMediaObject['ssrcGroups']!.add({
      'semantics': 'SIM',
      'ssrcs': ssrcs.join(' '),
    });

    // Add SSRCs with cname and msid
    for (final ssrc in ssrcs) {
      offerMediaObject['ssrcs']!.add({
        'id': ssrc,
        'attribute': 'cname',
        'value': cname,
      });
      
      offerMediaObject['ssrcs']!.add({
        'id': ssrc,
        'attribute': 'msid',
        'value': '$streamId $trackId',
      });
    }

    // Add RTX SSRCs if available
    if (rtxSsrcs.isNotEmpty) {
      for (var i = 0; i < rtxSsrcs.length; i++) {
        final ssrc = ssrcs[i];
        final rtxSsrc = rtxSsrcs[i];
        
        // Add RTX SSRC with cname and msid
        offerMediaObject['ssrcs']!.add({
          'id': rtxSsrc,
          'attribute': 'cname',
          'value': cname,
        });
        
        offerMediaObject['ssrcs']!.add({
          'id': rtxSsrc,
          'attribute': 'msid',
          'value': '$streamId $trackId',
        });
        
        // Add FID group for RTX
        offerMediaObject['ssrcGroups']!.add({
          'semantics': 'FID',
          'ssrcs': '$ssrc $rtxSsrc',
        });
      }
    }
  }
}
