import 'dart:math' as math;
import 'package:collection/collection.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sdp_transform/sdp_transform.dart';
import 'package:mediasoup_client_flutter/src/producer.dart';
import 'package:mediasoup_client_flutter/src/rtp_parameters.dart';
import 'package:mediasoup_client_flutter/src/sctp_parameters.dart';
import 'package:mediasoup_client_flutter/src/transport.dart';
import 'package:mediasoup_client_flutter/src/common/logger.dart';
import 'package:mediasoup_client_flutter/src/handlers/sdp/media_section.dart';
import 'package:mediasoup_client_flutter/src/type_conversion.dart';

Logger _logger = Logger('RemoteSdp');

class MediaSectionIdx {
  final int idx;
  final String? reuseMid;

  const MediaSectionIdx({required this.idx, this.reuseMid});

  factory MediaSectionIdx.fromMap(Map<String, dynamic> data) {
    return MediaSectionIdx(
      idx: data['idx'] as int,
      reuseMid: data['reuseMid'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'idx': idx,
      if (reuseMid != null) 'reuseMid': reuseMid,
    };
  }
}

class RemoteSdp {
  final IceParameters _iceParameters;
  final List<IceCandidate> _iceCandidates;
  final DtlsParameters _dtlsParameters;
  final SctpParameters? _sctpParameters;
  final PlainRtpParameters? _plainRtpParameters;
  final bool _planB;

  final List<Map<String, dynamic>> _mediaSections = [];
  final Map<String, int> _midToIndex = {};
  String? _firstMid;

  Map<String, dynamic> _sdpObject = {
    'version': 0,
    'origin': {
      'username': '-',
      'sessionId': DateTime.now().millisecondsSinceEpoch,
      'sessionVersion': 2,
      'netType': 'IN',
      'ipVer': 4,
      'address': '0.0.0.0'
    },
    'name': '-',
    'timing': {'start': 0, 'stop': 0},
    'media': [],
    'attributes': [],
  };

  RemoteSdp({
    required IceParameters iceParameters,
    required List<IceCandidate> iceCandidates,
    required DtlsParameters dtlsParameters,
    SctpParameters? sctpParameters,
    PlainRtpParameters? plainRtpParameters,
    bool planB = false,
  })  : _iceParameters = iceParameters,
        _iceCandidates = List.unmodifiable(iceCandidates),
        _dtlsParameters = dtlsParameters,
        _sctpParameters = sctpParameters,
        _plainRtpParameters = plainRtpParameters,
        _planB = planB {
    _logger.debug('constructor() [planB:$_planB]');

    _setupSessionLevelIceParameters();
    _setupSessionLevelDtlsParameters();
  }

  void _setupSessionLevelIceParameters() {
    if (_iceParameters.iceLite) {
      _addAttribute('ice-lite');
    }

    _addAttribute('ice-options', 'trickle');
    _addAttribute('ice-ufrag', _iceParameters.usernameFragment);
    _addAttribute('ice-pwd', _iceParameters.password);

    for (final candidate in _iceCandidates) {
      _addAttribute('candidate', _iceCandidateToSdp(candidate));
    }
  }

  void _setupSessionLevelDtlsParameters() {
    if (_dtlsParameters.fingerprints != null && _dtlsParameters.fingerprints!.isNotEmpty) {
      final fingerprint = _dtlsParameters.fingerprints!.first;
      _addAttribute('fingerprint', '${fingerprint.algorithm} ${fingerprint.value}');
    }

    String setup;
    switch (_dtlsParameters.role) {
      case DtlsRole.client:
        setup = 'active';
        break;
      case DtlsRole.server:
        setup = 'passive';
        break;
      default:
        setup = 'actpass';
    }
    _addAttribute('setup', setup);
  }

  void _addAttribute(String key, [dynamic value]) {
    _sdpObject['attributes'] ??= [];
    if (value == null) {
      _sdpObject['attributes']!.add({'key': key});
    } else {
      _sdpObject['attributes']!.add({'key': key, 'value': value.toString()});
    }
    _logger.debug('Added session attribute: $key=$value');
  }

  String _iceCandidateToSdp(IceCandidate candidate) {
    return '${candidate.foundation} ${candidate.component} ${candidate.protocol} ${candidate.priority} ${candidate.ip} ${candidate.port} typ ${candidate.type}';
  }

  int addNextMediaSection(Map<String, dynamic> mediaSection) {
    if (mediaSection == null) {
      _logger.error('addNextMediaSection() | mediaSection is null');
      throw Exception('mediaSection is null');
    }

    if (mediaSection['mid'] == null) {
      _logger.error('addNextMediaSection() | mid is null in mediaSection');
      throw Exception('mid is null');
    }

    final idx = _mediaSections.length;
    _mediaSections.add(mediaSection);
    _sdpObject['media']!.add(mediaSection);

    final mid = mediaSection['mid'].toString();
    _midToIndex[mid] = idx;

    if (_firstMid == null) _firstMid = mid;

    _logger.debug('addNextMediaSection() | Added media section at index $idx with mid: $mid');

    _regenerateBundleMids();

    return idx;
  }

  void replaceMediaSection(int index, Map<String, dynamic> newMediaSection) {
    if (index < 0 || index >= _mediaSections.length) {
      _logger.error('replaceMediaSection() | Invalid index: $index (sections: ${_mediaSections.length})');
      throw Exception('Invalid media section index');
    }

    if (newMediaSection == null) {
      _logger.error('replaceMediaSection() | newMediaSection is null');
      throw Exception('newMediaSection is null');
    }

    final oldMid = _mediaSections[index]['mid']?.toString();
    final newMid = newMediaSection['mid']?.toString();

    if (newMid == null) {
      _logger.error('replaceMediaSection() | newMid is null');
      throw Exception('newMid is null');
    }

    _mediaSections[index] = newMediaSection;
    _sdpObject['media']![index] = newMediaSection;

    if (oldMid != newMid) {
      if (oldMid != null) _midToIndex.remove(oldMid);
      _midToIndex[newMid] = index;
    }

    _logger.debug('replaceMediaSection() | Replaced media section at index $index (oldMid: $oldMid, newMid: $newMid)');

    _regenerateBundleMids();
  }

  void disableMediaSection(String mid) {
    final idx = _midToIndex[mid];
    if (idx == null) {
      _logger.warn('disableMediaSection() | No section for mid: $mid');
      return;
    }

    final mediaSection = _mediaSections[idx];
    mediaSection['port'] = 0;
    mediaSection['direction'] = 'inactive';

    _logger.debug('disableMediaSection() | Disabled media section for mid: $mid at index $idx');
  }

  void closeMediaSection(String mid) {
    _logger.debug('closeMediaSection() called for mid: $mid');
    
    final idx = _midToIndex[mid];
    if (idx == null) {
      _logger.warn('closeMediaSection() | No section for mid: $mid');
      return;
    }

    // ✅ FIX: Instead of removing, mark as inactive (maintains m-line order)
    final mediaSection = _mediaSections[idx];
    
    // Set port to 0 and direction to inactive (RFC 4566)
    mediaSection['port'] = 0;
    mediaSection['direction'] = 'inactive';
    
    // Remove all attributes except basic ones
    mediaSection['rtp'] = [];
    mediaSection['fmtp'] = [];
    mediaSection['rtcpFb'] = [];
    mediaSection['ssrcs'] = [];
    mediaSection['ssrcGroups'] = [];
    mediaSection['ext'] = [];
    
    _logger.debug('closeMediaSection() | Marked section as inactive for mid: $mid at index $idx');

    // ✅ FIX: Don't remove from arrays - just mark closed
    mediaSection['closed'] = true;
    
    // Update SDP object
    _sdpObject['media'][idx] = mediaSection;
    
    _logger.debug('closeMediaSection() | Media section closed: $mid');
    _regenerateBundleMids();
  }

  MediaSectionIdx getNextMediaSectionIdx() {
    for (int idx = 0; idx < _mediaSections.length; ++idx) {
      if (_mediaSections[idx]['closed'] == true) {
        _logger.debug('getNextMediaSectionIdx() | Found closed section at index $idx');
        return MediaSectionIdx(idx: idx);
      }
    }
    final nextIdx = _mediaSections.length;
    _logger.debug('getNextMediaSectionIdx() | No closed sections, using next index: $nextIdx');
    return MediaSectionIdx(idx: nextIdx);
  }

  String getSdp() {
    final sdp = write(_sdpObject, null);
    _logger.debug('getSdp() | Generated SDP: $sdp');
    return sdp;
  }

  void updateIceParameters(IceParameters iceParameters) {
    _logger.debug('updateIceParameters() [iceParameters:$iceParameters]');

    _removeAttributes(['ice-ufrag', 'ice-pwd', 'ice-lite', 'ice-options', 'candidate']);

    if (iceParameters.iceLite) _addAttribute('ice-lite');
    _addAttribute('ice-options', 'trickle');
    _addAttribute('ice-ufrag', iceParameters.usernameFragment ?? '');
    _addAttribute('ice-pwd', iceParameters.password ?? '');

    for (final candidate in _iceCandidates) {
      _addAttribute('candidate', _iceCandidateToSdp(candidate));
    }
  }

  void updateDtlsRole(DtlsRole role) {
    _logger.debug('updateDtlsRole() [role:$role]');

    String setup;
    switch (role) {
      case DtlsRole.client:
        setup = 'active';
        break;
      case DtlsRole.server:
        setup = 'passive';
        break;
      default:
        setup = 'actpass';
    }

    _removeAttributes(['setup']);
    _addAttribute('setup', setup);
  }
  void receive({
    required String mid,
    required RTCRtpMediaType kind,
    required RtpParameters offerRtpParameters,
    required String streamId,
    required String trackId,
  }) {
    final logger = Logger('RemoteSdp:receive');
    
    // 🚨 FIX: Validate all inputs before processing
    if (mid.isEmpty) {
      logger.error('receive() called with empty mid');
      throw Exception('mid cannot be empty');
    }
    
    if (streamId.isEmpty) {
      logger.error('receive() called with empty streamId');
      throw Exception('streamId cannot be empty');
    }
    
    if (trackId.isEmpty) {
      logger.error('receive() called with empty trackId');
      throw Exception('trackId cannot be empty');
    }
    
    if (offerRtpParameters.codecs.isEmpty) {
      logger.error('receive() called with no codecs in offerRtpParameters');
      throw Exception('No codecs for receive - check codec negotiation');
    }
    
    logger.debug('receive() | Adding media section [mid:$mid, kind:$kind, codecs count: ${offerRtpParameters.codecs.length}]');

    final idx = getNextMediaSectionIdx();
    final ssrc = _generateUniqueSsrc();

    // 🚨 FIX: Generate cname from streamId if rtcp.cname is null
    final cname = offerRtpParameters.rtcp?.cname ?? 'stream-${streamId.substring(0, 8)}';
    
    logger.debug('receive() | Using cname: $cname (from rtcp: ${offerRtpParameters.rtcp?.cname != null})');
    
    final mediaSection = {
      'type': TypeConversion.rtcMediaTypeToString(kind),
      'mid': mid,
      'port': 7,
      'protocol': 'UDP/TLS/RTP/SAVPF',
      'connection': {'ip': '0.0.0.0', 'version': 4},
      'direction': 'recvonly',
      'rtp': offerRtpParameters.codecs
          .map((codec) {
            // 🚨 FIX: Validate codec has required fields
            if (codec.mimeType.isEmpty) {
              logger.error('Codec missing mimeType');
              throw Exception('Invalid codec - missing mimeType');
            }
            
            final parts = codec.mimeType.split('/');
            if (parts.length != 2) {
              logger.error('Invalid codec mimeType format: ${codec.mimeType}');
              throw Exception('Invalid codec mimeType format');
            }
            
            return {
              'payload': codec.payloadType,
              'codec': parts[1],
              'rate': codec.clockRate,
              if (codec.channels != null && codec.channels! > 1) 'channels': codec.channels,
            };
          })
          .toList(),
      'rtcp': {'cname': cname, 'reducedSize': true},
      'fmtp': offerRtpParameters.codecs
          .where((codec) => codec.parameters.isNotEmpty)
          .map((codec) => {
                'payload': codec.payloadType,
                'config': codec.parameters.entries
                    .map((e) => '${e.key}=${e.value}')
                    .join(';')
              })
          .toList(),
      'payloads': offerRtpParameters.codecs.map((c) => c.payloadType).join(' '),
      'ext': offerRtpParameters.headerExtensions
          .map((ext) => {'uri': ext.uri, 'id': ext.id})
          .toList(),
      'ssrcs': [
        {
          'id': ssrc,
          'attribute': 'cname',
          'value': cname,
        },
        {
          'id': ssrc,
          'attribute': 'msid',
          'value': '$streamId $trackId',
        },
      ],
    };

    logger.debug('receive() | Generated SSRC for $kind: $ssrc');
    logger.debug('receive() | Adding media section [mid:$mid, kind:$kind, idx:${idx.idx}, ssrc:$ssrc]');

    if (idx.reuseMid != null) {
      replaceMediaSection(idx.idx, mediaSection);
    } else {
      addNextMediaSection(mediaSection);
    }
  }

  void receiveSctpAssociation() {
    if (_sctpParameters == null) {
      _logger.error('receiveSctpAssociation() | No SCTP parameters provided');
      throw Exception('SCTP parameters not available');
    }

    final mediaSection = {
      'type': 'application',
      'port': 5000,
      'protocol': 'UDP/DTLS/SCTP',
      'payloads': 'webrtc-datachannel',
      'sctpPort': _sctpParameters!.port,
      'maxMessageSize': _sctpParameters!.maxMessageSize,
      'direction': 'recvonly',
    };

    _logger.debug('receiveSctpAssociation() | Adding SCTP media section');

    addNextMediaSection(mediaSection);
  }

  void sendSctpAssociation(Map<String, dynamic> offerMediaObject) {
    if (_sctpParameters == null) {
      _logger.error('sendSctpAssociation() | No SCTP parameters provided');
      throw Exception('SCTP parameters not available');
    }

    final mediaSection = {
      'type': 'application',
      'port': 5000,
      'protocol': 'UDP/DTLS/SCTP',
      'payloads': 'webrtc-datachannel',
      'sctpPort': _sctpParameters!.port,
      'maxMessageSize': _sctpParameters!.maxMessageSize,
      'direction': 'sendonly',
    };

    _logger.debug('sendSctpAssociation() | Adding SCTP media section from offer: $offerMediaObject');

    final idx = getNextMediaSectionIdx();
    if (idx.reuseMid != null) {
      replaceMediaSection(idx.idx, mediaSection);
    } else {
      addNextMediaSection(mediaSection);
    }
  }

  int _generateUniqueSsrc() {
    return (math.Random().nextDouble() * 4294967295).floor();
  }

  void _removeAttributes(List<String> keys) {
    _sdpObject['attributes'] ??= [];
    _sdpObject['attributes']!.removeWhere((attr) => keys.contains(attr['key']));
    _logger.debug('Removed attributes: $keys');
  }

  void _regenerateBundleMids() {
    _removeAttributes(['group']);

    if (_mediaSections.isEmpty) return;

    // ✅ FIX: Only include active (non-closed) mids in BUNDLE
    final activeMids = _mediaSections
        .where((s) => s['closed'] != true)
        .map((s) => s['mid']?.toString())
        .whereType<String>()
        .toList();
        
    if (activeMids.isNotEmpty) {
      _addAttribute('group', 'BUNDLE ${activeMids.join(' ')}');
      _logger.debug('Regenerated BUNDLE group with active mids: $activeMids');
    }
  }
}