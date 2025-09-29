import 'package:webrtc_interface/webrtc_interface.dart';
import 'package:mediasoup_client_flutter/src/rtp_parameters.dart';

class TypeConversion {
  static MediaKind rtcToMediaKind(RTCRtpMediaType rtcType) {
    switch (rtcType) {
      case RTCRtpMediaType.RTCRtpMediaTypeAudio:
        return MediaKind.audio;
      case RTCRtpMediaType.RTCRtpMediaTypeVideo:
        return MediaKind.video;
      case RTCRtpMediaType.RTCRtpMediaTypeData:
        return MediaKind.application;
      default:
        return MediaKind.audio;
    }
  }

  static RTCRtpMediaType mediaKindToRtc(MediaKind mediaKind) {
    switch (mediaKind) {
      case MediaKind.audio:
        return RTCRtpMediaType.RTCRtpMediaTypeAudio;
      case MediaKind.video:
        return RTCRtpMediaType.RTCRtpMediaTypeVideo;
      case MediaKind.application:
        return RTCRtpMediaType.RTCRtpMediaTypeData;
    }
  }

  static String mediaKindToString(MediaKind kind) {
    return kind.toString().split('.').last;
  }

  static MediaKind stringToMediaKind(String value) {
    return MediaKind.values.firstWhere(
      (kind) => kind.toString().split('.').last == value,
      orElse: () => MediaKind.audio,
    );
  }

  static RTCRtpMediaType stringToRtcMediaType(String value) {
    switch (value) {
      case 'audio':
        return RTCRtpMediaType.RTCRtpMediaTypeAudio;
      case 'video':
        return RTCRtpMediaType.RTCRtpMediaTypeVideo;
      case 'application':
      case 'data':
        return RTCRtpMediaType.RTCRtpMediaTypeData;
      default:
        return RTCRtpMediaType.RTCRtpMediaTypeAudio;
    }
  }

  static String rtcMediaTypeToString(RTCRtpMediaType type) {
    switch (type) {
      case RTCRtpMediaType.RTCRtpMediaTypeAudio:
        return 'audio';
      case RTCRtpMediaType.RTCRtpMediaTypeVideo:
        return 'video';
      case RTCRtpMediaType.RTCRtpMediaTypeData:
        return 'application';
      default:
        return 'audio';
    }
  }
}