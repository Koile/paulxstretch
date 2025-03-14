/*
  ==============================================================================

   This file is part of the JUCE library.
   Copyright (c) 2022 - Raw Material Software Limited

   JUCE is an open source library subject to commercial or open-source
   licensing.

   By using JUCE, you agree to the terms of both the JUCE 7 End-User License
   Agreement and JUCE Privacy Policy.

   End User License Agreement: www.juce.com/juce-7-licence
   Privacy Policy: www.juce.com/juce-privacy-policy

   Or: You may also use this code under the terms of the GPL v3 (see
   www.gnu.org/licenses).

   JUCE IS PROVIDED "AS IS" WITHOUT ANY WARRANTY, AND ALL WARRANTIES, WHETHER
   EXPRESSED OR IMPLIED, INCLUDING MERCHANTABILITY AND FITNESS FOR PURPOSE, ARE
   DISCLAIMED.

  ==============================================================================
*/


/*******************************************************************************
 The block below describes the properties of this module, and is read by
 the Projucer to automatically generate project code that uses it.
 For details about the syntax and how to create or use a module, see the
 JUCE Module Format.md file.


 BEGIN_JUCE_MODULE_DECLARATION

  ID:                 juce_video
  vendor:             juce
  version:            7.0.2
  name:               JUCE video playback and capture classes
  description:        Classes for playing video and capturing camera input.
  website:            http://www.juce.com/juce
  license:            GPL/Commercial
  minimumCppStandard: 17

  dependencies:       juce_gui_extra
  OSXFrameworks:      AVKit AVFoundation CoreMedia
  iOSFrameworks:      AVKit AVFoundation CoreMedia

 END_JUCE_MODULE_DECLARATION

*******************************************************************************/


#pragma once
#define JUCE_VIDEO_H_INCLUDED

//==============================================================================
#include <juce_gui_extra/juce_gui_extra.h>

//==============================================================================
/** Config: JUCE_USE_CAMERA
    Enables camera support using the CameraDevice class (Mac, Windows, iOS, Android).
*/
#ifndef JUCE_USE_CAMERA
 #define JUCE_USE_CAMERA 0
#endif

#ifndef JUCE_CAMERA_LOG_ENABLED
 #define JUCE_CAMERA_LOG_ENABLED 0
#endif

#if JUCE_CAMERA_LOG_ENABLED
 #define JUCE_CAMERA_LOG(x) DBG(x)
#else
 #define JUCE_CAMERA_LOG(x) {}
#endif

#if ! (JUCE_MAC || JUCE_WINDOWS || JUCE_IOS || JUCE_ANDROID)
 #undef JUCE_USE_CAMERA
#endif

//==============================================================================
/** Config: JUCE_SYNC_VIDEO_VOLUME_WITH_OS_MEDIA_VOLUME
    Enables synchronisation between video playback volume and OS media volume.
    Currently supported on Android only.
 */
#ifndef JUCE_SYNC_VIDEO_VOLUME_WITH_OS_MEDIA_VOLUME
 #define JUCE_SYNC_VIDEO_VOLUME_WITH_OS_MEDIA_VOLUME 1
#endif

#ifndef JUCE_VIDEO_LOG_ENABLED
 #define JUCE_VIDEO_LOG_ENABLED 1
#endif

#if JUCE_VIDEO_LOG_ENABLED
 #define JUCE_VIDEO_LOG(x) DBG(x)
#else
 #define JUCE_VIDEO_LOG(x) {}
#endif

//==============================================================================
#include "playback/juce_VideoComponent.h"
#include "capture/juce_CameraDevice.h"
