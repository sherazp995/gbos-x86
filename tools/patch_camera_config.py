#!/usr/bin/env python3
"""Keep Google's USB camera HAL from crashing when there is no VA-API driver (AMD laptops): software JPEG decoding instead.

  patch_camera_config.py IN OUT      (IN = /vendor/etc/camera/internal_usb_camera_info.txtpb)

The webcam (uvcvideo, MJPEG) never worked on the ThinkPad X13 Gen 2 AMD: every time the camera app opened it,
android.hardware.camera.provider-usb-service.android-desktop aborted (`called Option::unwrap() on a None value`) in
desktop_camera_common::jpeg::hw_decoder_vaapi::RESOLUTION_BOUND, reached from HardwareJpegDecoderVaapi::new. libva looks for the
DRM driver's VA driver (radeonsi_drv_video.so; Google ships only iHD_drv_video.so) and va_openDriver() returns -1.

The HAL only tries the hardware decoder when this file says `use_hardware_jpeg_decoder: true`:
desktop_usb_camera_hal::pipeline::jpeg_decoder::maybe_create_hardware_jpeg_decoder returns None (no hardware decoder, MJPEG is
decoded in software) when that field of the parsed file is false. The struct the HAL parses it into holds, in the same order as
the file, face_detection_input_width (an optional u32), camera_modules (a map) and use_hardware_jpeg_decoder (a bool), and the
check (`cmpb $0x1` on the bool) comes before any VA-API call. The copy written here only flips that field; hook.sh binds it in
software-GPU mode (no Intel GPU), so Intel laptops keep their hardware JPEG decoder.

Only applied to the exact original (sha256 pinned): another Google build may change the file.
"""
import hashlib, sys

ORIG_SHA = 'b3f9739f419feed5dcd02d3d0451fc9904322b8babb3150f792475b1fdb0c105'
ON = b'use_hardware_jpeg_decoder: true\n'
OFF = b'use_hardware_jpeg_decoder: false\n'


def main():
    src, dst = sys.argv[1], sys.argv[2]
    d = open(src, 'rb').read()
    if hashlib.sha256(d).hexdigest() != ORIG_SHA:
        sys.exit('unexpected internal_usb_camera_info.txtpb (sha256 differs from the build this patch was made for)')
    assert d.count(b'use_hardware_jpeg_decoder') == 1 and d.startswith(ON), 'use_hardware_jpeg_decoder line moved'
    open(dst, 'wb').write(OFF + d[len(ON):])
    print('patched: use_hardware_jpeg_decoder: false (MJPEG decoded in software)')


if __name__ == '__main__':
    main()
