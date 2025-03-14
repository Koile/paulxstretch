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

#include <juce_core/system/juce_TargetPlatform.h>
#include "../utility/juce_CheckSettingMacros.h"

#if JucePlugin_Build_AUv3

#if JUCE_MAC && ! (defined (MAC_OS_X_VERSION_10_11) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_11)
 #error AUv3 needs Deployment Target OS X 10.11 or higher to compile
#endif

#if (JUCE_IOS && defined (__IPHONE_15_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_15_0) \
   || (JUCE_MAC && defined (MAC_OS_VERSION_12_0) && MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_VERSION_12_0)
 #define JUCE_AUV3_MIDI_EVENT_LIST_SUPPORTED 1
#endif

#ifndef __OBJC2__
 #error AUv3 needs Objective-C 2 support (compile with 64-bit)
#endif

#define JUCE_CORE_INCLUDE_OBJC_HELPERS 1

#include "../utility/juce_IncludeSystemHeaders.h"
#include "../utility/juce_IncludeModuleHeaders.h"

#import <CoreAudioKit/CoreAudioKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#include <juce_graphics/native/juce_mac_CoreGraphicsHelpers.h>
#include <juce_audio_basics/native/juce_mac_CoreAudioLayouts.h>
#include <juce_audio_basics/native/juce_mac_CoreAudioTimeConversions.h>
#include <juce_audio_processors/format_types/juce_LegacyAudioParameter.cpp>
#include <juce_audio_processors/format_types/juce_AU_Shared.h>

#if JUCE_AUV3_MIDI_EVENT_LIST_SUPPORTED
 #include <juce_audio_basics/midi/ump/juce_UMP.h>
#endif

#define JUCE_VIEWCONTROLLER_OBJC_NAME(x) JUCE_JOIN_MACRO (x, FactoryAUv3)

#if JUCE_IOS
 #define JUCE_IOS_MAC_VIEW  UIView
#else
 #define JUCE_IOS_MAC_VIEW  NSView
#endif

#define JUCE_AUDIOUNIT_OBJC_NAME(x) JUCE_JOIN_MACRO (x, AUv3)

#include <future>

JUCE_BEGIN_IGNORE_WARNINGS_GCC_LIKE ("-Wnullability-completeness")

using namespace juce;

struct AudioProcessorHolder  : public ReferenceCountedObject
{
    AudioProcessorHolder() = default;
    explicit AudioProcessorHolder (AudioProcessor* p) : processor (p) {}
    AudioProcessor& operator*() noexcept        { return *processor; }
    AudioProcessor* operator->() noexcept       { return processor.get(); }
    AudioProcessor* get() noexcept              { return processor.get(); }

    struct ViewConfig
    {
        double width;
        double height;
        bool hostHasMIDIController;
    };

    std::unique_ptr<ViewConfig> viewConfiguration;

    using Ptr = ReferenceCountedObjectPtr<AudioProcessorHolder>;

private:
    std::unique_ptr<AudioProcessor> processor;

    AudioProcessorHolder& operator= (AudioProcessor*) = delete;
    AudioProcessorHolder (AudioProcessorHolder&) = delete;
    AudioProcessorHolder& operator= (AudioProcessorHolder&) = delete;
};

//==============================================================================
//=========================== The actual AudioUnit =============================
//==============================================================================
class JuceAudioUnitv3  : public AudioProcessorListener,
                         public AudioPlayHead,
                         private AudioProcessorParameter::Listener
{
public:
    JuceAudioUnitv3 (const AudioProcessorHolder::Ptr& processor,
                     const AudioComponentDescription& descr,
                     AudioComponentInstantiationOptions options,
                     NSError** error)
        JUCE_BEGIN_IGNORE_WARNINGS_GCC_LIKE ("-Wobjc-method-access")
        : au ([getClass().createInstance() initWithComponentDescription: descr
                                                                options: options
                                                                  error: error
                                                              juceClass: this]),
        JUCE_END_IGNORE_WARNINGS_GCC_LIKE
          processorHolder (processor)
    {
        init();
    }

    JuceAudioUnitv3 (AUAudioUnit* audioUnit, AudioComponentDescription, AudioComponentInstantiationOptions, NSError**)
        : au (audioUnit),
          processorHolder (new AudioProcessorHolder (createPluginFilterOfType (AudioProcessor::wrapperType_AudioUnitv3)))
    {
        jassert (MessageManager::getInstance()->isThisTheMessageThread());
        initialiseJuce_GUI();

        init();
    }

    ~JuceAudioUnitv3() override
    {
        auto& processor = getAudioProcessor();
        processor.removeListener (this);

        if (bypassParam != nullptr)
            bypassParam->removeListener (this);

        removeEditor (processor);

        if (editorObserverToken != nullptr)
        {
            [paramTree.get() removeParameterObserver: editorObserverToken];
            editorObserverToken = nullptr;
        }
    }

    //==============================================================================
    void init()
    {
        inParameterChangedCallback = false;

        AudioProcessor& processor = getAudioProcessor();
        const AUAudioFrameCount maxFrames = [au maximumFramesToRender];

       #ifdef JucePlugin_PreferredChannelConfigurations
        short configs[][2] = {JucePlugin_PreferredChannelConfigurations};
        const int numConfigs = sizeof (configs) / sizeof (short[2]);

        jassert (numConfigs > 0 && (configs[0][0] > 0 || configs[0][1] > 0));
        processor.setPlayConfigDetails (configs[0][0], configs[0][1], kDefaultSampleRate, static_cast<int> (maxFrames));

        Array<AUChannelInfo> channelInfos;

        for (int i = 0; i < numConfigs; ++i)
        {
            AUChannelInfo channelInfo;

            channelInfo.inChannels  = configs[i][0];
            channelInfo.outChannels = configs[i][1];

            channelInfos.add (channelInfo);
        }
       #else
        Array<AUChannelInfo> channelInfos = AudioUnitHelpers::getAUChannelInfo (processor);
       #endif

        processor.setPlayHead (this);

        totalInChannels  = processor.getTotalNumInputChannels();
        totalOutChannels = processor.getTotalNumOutputChannels();

        {
            channelCapabilities.reset ([[NSMutableArray<NSNumber*> alloc] init]);

            for (int i = 0; i < channelInfos.size(); ++i)
            {
                AUChannelInfo& info = channelInfos.getReference (i);

                [channelCapabilities.get() addObject: [NSNumber numberWithInteger: info.inChannels]];
                [channelCapabilities.get() addObject: [NSNumber numberWithInteger: info.outChannels]];
            }
        }

        editorObserverToken = nullptr;
        internalRenderBlock = CreateObjCBlock (this, &JuceAudioUnitv3::renderCallback);

        processor.setRateAndBufferSizeDetails (kDefaultSampleRate, static_cast<int> (maxFrames));
        processor.prepareToPlay (kDefaultSampleRate, static_cast<int> (maxFrames));
        processor.addListener (this);

        addParameters();
        addPresets();

        addAudioUnitBusses (true);
        addAudioUnitBusses (false);
    }

    AudioProcessor& getAudioProcessor() const noexcept        { return **processorHolder; }

    //==============================================================================
    void reset()
    {
        midiMessages.clear();
        lastTimeStamp.mSampleTime = std::numeric_limits<Float64>::max();
        lastTimeStamp.mFlags = 0;
    }

    //==============================================================================
    AUAudioUnitPreset* getCurrentPreset() const
    {
        return factoryPresets.getAtIndex (getAudioProcessor().getCurrentProgram());
    }

    void setCurrentPreset (AUAudioUnitPreset* preset)
    {
        getAudioProcessor().setCurrentProgram (static_cast<int> ([preset number]));
    }

    NSArray<AUAudioUnitPreset*>* getFactoryPresets() const
    {
        return factoryPresets.get();
    }

    NSDictionary<NSString*, id>* getFullState() const
    {
        NSMutableDictionary<NSString*, id>* retval = [[NSMutableDictionary<NSString*, id> alloc] init];

        {
            auto* superRetval = ObjCMsgSendSuper<AUAudioUnit, NSDictionary<NSString*, id>*> (au, @selector (fullState));

            if (superRetval != nullptr)
                [retval addEntriesFromDictionary:superRetval];
        }

        juce::MemoryBlock state;

       #if JUCE_AU_WRAPPERS_SAVE_PROGRAM_STATES
        getAudioProcessor().getCurrentProgramStateInformation (state);
       #else
        getAudioProcessor().getStateInformation (state);
       #endif

        if (state.getSize() > 0)
        {
            NSData* ourState = [[NSData alloc] initWithBytes: state.getData()
                                                      length: state.getSize()];

            NSString* nsKey = [[NSString alloc] initWithUTF8String: JUCE_STATE_DICTIONARY_KEY];

            [retval setObject: ourState
                       forKey: nsKey];

            [nsKey    release];
            [ourState release];
        }

        return [retval autorelease];
    }

    void setFullState (NSDictionary<NSString*, id>* state)
    {
        if (state == nullptr)
            return;

        NSMutableDictionary<NSString*, id>* modifiedState = [[NSMutableDictionary<NSString*, id> alloc] init];
        [modifiedState addEntriesFromDictionary: state];

        NSString* nsPresetKey = [[NSString alloc] initWithUTF8String: kAUPresetDataKey];
        [modifiedState removeObjectForKey: nsPresetKey];
        [nsPresetKey release];

        ObjCMsgSendSuper<AUAudioUnit, void> (au, @selector (setFullState:), state);

        NSString* nsKey = [[NSString alloc] initWithUTF8String: JUCE_STATE_DICTIONARY_KEY];
        NSObject* obj = [modifiedState objectForKey: nsKey];
        [nsKey release];

        if (obj != nullptr)
        {
            if ([obj isKindOfClass:[NSData class]])
            {
                NSData* data = reinterpret_cast<NSData*> (obj);
                const int numBytes = static_cast<int> ([data length]);
                const juce::uint8* const rawBytes = reinterpret_cast< const juce::uint8* const> ([data bytes]);

                if (numBytes > 0)
                {
                   #if JUCE_AU_WRAPPERS_SAVE_PROGRAM_STATES
                    getAudioProcessor().setCurrentProgramStateInformation (rawBytes, numBytes);
                   #else
                    getAudioProcessor().setStateInformation (rawBytes, numBytes);
                   #endif
                }
            }
        }

        [modifiedState release];
    }

    AUParameterTree* getParameterTree() const
    {
        return paramTree.get();
    }

    NSArray<NSNumber*>* parametersForOverviewWithCount (int count) const
    {
        const int n = static_cast<int> ([overviewParams.get() count]);

        if (count >= n)
            return overviewParams.get();

        NSMutableArray<NSNumber*>* retval = [[NSMutableArray<NSNumber*>alloc] initWithArray: overviewParams.get()];
        [retval removeObjectsInRange: NSMakeRange (static_cast<unsigned int> (count), static_cast<unsigned int> (n - count))];

        return [retval autorelease];
    }

    //==============================================================================
    NSTimeInterval getLatency() const
    {
        auto& p = getAudioProcessor();
        return p.getLatencySamples() / p.getSampleRate();
    }

    NSTimeInterval getTailTime() const
    {
        return getAudioProcessor().getTailLengthSeconds();
    }

    //==============================================================================
    AUAudioUnitBusArray* getInputBusses()             const { return inputBusses.get();  }
    AUAudioUnitBusArray* getOutputBusses()            const { return outputBusses.get(); }
    NSArray<NSNumber*>* getChannelCapabilities()      const { return channelCapabilities.get(); }

    bool shouldChangeToFormat (AVAudioFormat* format, AUAudioUnitBus* auBus)
    {
        const bool isInput = ([auBus busType] == AUAudioUnitBusTypeInput);
        const int busIdx = static_cast<int> ([auBus index]);
        const int newNumChannels = static_cast<int> ([format channelCount]);

        AudioProcessor& processor = getAudioProcessor();

        if (AudioProcessor::Bus* bus = processor.getBus (isInput, busIdx))
        {
          #ifdef JucePlugin_PreferredChannelConfigurations
            ignoreUnused (bus);

            short configs[][2] = {JucePlugin_PreferredChannelConfigurations};

            if (! AudioUnitHelpers::isLayoutSupported (processor, isInput, busIdx, newNumChannels, configs))
                return false;
          #else
            const AVAudioChannelLayout* layout    = [format channelLayout];
            const AudioChannelLayoutTag layoutTag = (layout != nullptr ? [layout layoutTag] : 0);

            if (layoutTag != 0)
            {
                AudioChannelSet newLayout = CoreAudioLayouts::fromCoreAudio (layoutTag);

                if (newLayout.size() != newNumChannels)
                    return false;

                if (! bus->isLayoutSupported (newLayout))
                    return false;
            }
            else
            {
                if (! bus->isNumberOfChannelsSupported (newNumChannels))
                    return false;
            }
           #endif

            return true;
        }

        return false;
    }

    //==============================================================================
    int getVirtualMIDICableCount() const
    {
       #if JucePlugin_WantsMidiInput
        return 1;
       #else
        return 0;
       #endif
    }

    bool getSupportsMPE() const
    {
        return getAudioProcessor().supportsMPE();
    }

    NSArray<NSString*>* getMIDIOutputNames() const
    {
       #if JucePlugin_ProducesMidiOutput
        return @[@"MIDI Out"];
       #else
        return @[];
       #endif
    }

    //==============================================================================
    AUInternalRenderBlock getInternalRenderBlock() const  { return internalRenderBlock; }
    bool getRenderingOffline()                     const  { return getAudioProcessor().isNonRealtime(); }
    void setRenderingOffline (bool offline)
    {
        auto& processor = getAudioProcessor();
        auto isCurrentlyNonRealtime = processor.isNonRealtime();

        if (isCurrentlyNonRealtime != offline)
        {
            ScopedLock callbackLock (processor.getCallbackLock());

            processor.setNonRealtime (offline);
            processor.prepareToPlay (processor.getSampleRate(), processor.getBlockSize());
        }
    }

    bool getShouldBypassEffect() const
    {
        if (bypassParam != nullptr)
            return (bypassParam->getValue() != 0.0f);

        return (ObjCMsgSendSuper<AUAudioUnit, BOOL> (au, @selector (shouldBypassEffect)) == YES);
    }

    void setShouldBypassEffect (bool shouldBypass)
    {
        if (bypassParam != nullptr)
            bypassParam->setValue (shouldBypass ? 1.0f : 0.0f);

        ObjCMsgSendSuper<AUAudioUnit, void> (au, @selector (setShouldBypassEffect:), shouldBypass ? YES : NO);
    }

    //==============================================================================
    NSString* getContextName() const                  { return juceStringToNS (contextName); }
    void setContextName (NSString* str)
    {
        if (str != nullptr)
        {
            AudioProcessor::TrackProperties props;
            props.name = nsStringToJuce (str);

            getAudioProcessor().updateTrackProperties (props);
        }
    }

    //==============================================================================
    bool allocateRenderResourcesAndReturnError (NSError **outError)
    {
        AudioProcessor& processor = getAudioProcessor();
        const AUAudioFrameCount maxFrames = [au maximumFramesToRender];

        if (ObjCMsgSendSuper<AUAudioUnit, BOOL, NSError**> (au, @selector (allocateRenderResourcesAndReturnError:), outError) == NO)
            return false;

        if (outError != nullptr)
            *outError = nullptr;

        AudioProcessor::BusesLayout layouts;
        for (int dir = 0; dir < 2; ++dir)
        {
            const bool isInput = (dir == 0);
            const int n = AudioUnitHelpers::getBusCountForWrapper (processor, isInput);
            Array<AudioChannelSet>& channelSets = (isInput ? layouts.inputBuses : layouts.outputBuses);

            AUAudioUnitBusArray* auBuses = (isInput ? [au inputBusses] : [au outputBusses]);
            jassert ([auBuses count] == static_cast<NSUInteger> (n));

            for (int busIdx = 0; busIdx < n; ++busIdx)
            {
                if (AudioProcessor::Bus* bus = processor.getBus (isInput, busIdx))
                {
                    AVAudioFormat* format = [[auBuses objectAtIndexedSubscript:static_cast<NSUInteger> (busIdx)] format];

                    AudioChannelSet newLayout;
                    const AVAudioChannelLayout* layout    = [format channelLayout];
                    const AudioChannelLayoutTag layoutTag = (layout != nullptr ? [layout layoutTag] : 0);

                    if (layoutTag != 0)
                        newLayout = CoreAudioLayouts::fromCoreAudio (layoutTag);
                    else
                        newLayout = bus->supportedLayoutWithChannels (static_cast<int> ([format channelCount]));

                    if (newLayout.isDisabled())
                        return false;

                    channelSets.add (newLayout);
                }
            }
        }

       #ifdef JucePlugin_PreferredChannelConfigurations
        short configs[][2] = {JucePlugin_PreferredChannelConfigurations};

        if (! AudioProcessor::containsLayout (layouts, configs))
        {
            if (outError != nullptr)
                *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nullptr];

            return false;
        }
       #endif

        if (! AudioUnitHelpers::setBusesLayout (&getAudioProcessor(), layouts))
        {
            if (outError != nullptr)
                *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nullptr];

            return false;
        }

        totalInChannels  = processor.getTotalNumInputChannels();
        totalOutChannels = processor.getTotalNumOutputChannels();

        allocateBusBuffer (true);
        allocateBusBuffer (false);

        mapper.alloc (processor);

        audioBuffer.prepare (AudioUnitHelpers::getBusesLayout (&processor), static_cast<int> (maxFrames));

        auto sampleRate = [&]
        {
            for (auto* buffer : { inputBusses.get(), outputBusses.get() })
                if ([buffer count] > 0)
                    return [[[buffer objectAtIndexedSubscript: 0] format] sampleRate];

            return 44100.0;
        }();

        processor.setRateAndBufferSizeDetails (sampleRate, static_cast<int> (maxFrames));
        processor.prepareToPlay (sampleRate, static_cast<int> (maxFrames));

        midiMessages.ensureSize (2048);
        midiMessages.clear();

        hostMusicalContextCallback = [au musicalContextBlock];
        hostTransportStateCallback = [au transportStateBlock];

        if (@available (macOS 10.13, iOS 11.0, *))
            midiOutputEventBlock = [au MIDIOutputEventBlock];

        reset();

        return true;
    }

    void deallocateRenderResources()
    {
        midiOutputEventBlock = nullptr;

        hostMusicalContextCallback = nullptr;
        hostTransportStateCallback = nullptr;

        getAudioProcessor().releaseResources();
        audioBuffer.release();

        inBusBuffers. clear();
        outBusBuffers.clear();

        mapper.release();

        ObjCMsgSendSuper<AUAudioUnit, void> (au, @selector (deallocateRenderResources));
    }

    //==============================================================================
    struct ScopedKeyChange
    {
        ScopedKeyChange (AUAudioUnit* a, NSString* k)
            : au (a), key (k)
        {
            [au willChangeValueForKey: key];
        }

        ~ScopedKeyChange()
        {
            [au didChangeValueForKey: key];
        }

        AUAudioUnit* au;
        NSString* key;
    };

    //==============================================================================
    void audioProcessorChanged (AudioProcessor* processor, const ChangeDetails& details) override
    {
        ignoreUnused (processor);

        if (! details.programChanged)
            return;

        {
            ScopedKeyChange scope (au, @"allParameterValues");
            addPresets();
        }

        {
            ScopedKeyChange scope (au, @"currentPreset");
        }
    }

    void sendParameterEvent (int idx, const float* newValue, AUParameterAutomationEventType type)
    {
        if (inParameterChangedCallback.get())
        {
            inParameterChangedCallback = false;
            return;
        }

        if (auto* juceParam = juceParameters.getParamForIndex (idx))
        {
            if (auto* param = [paramTree.get() parameterWithAddress: getAUParameterAddressForIndex (idx)])
            {
                const auto value = (newValue != nullptr ? *newValue : juceParam->getValue()) * getMaximumParameterValue (juceParam);

                if (@available (macOS 10.12, iOS 10.0, *))
                {
                    [param setValue: value
                         originator: editorObserverToken
                         atHostTime: lastTimeStamp.mHostTime
                          eventType: type];
                }
                else if (type == AUParameterAutomationEventTypeValue)
                {
                    [param setValue: value originator: editorObserverToken];
                }
            }
        }
    }

    void audioProcessorParameterChanged (AudioProcessor*, int idx, float newValue) override
    {
        sendParameterEvent (idx, &newValue, AUParameterAutomationEventTypeValue);
    }

    void audioProcessorParameterChangeGestureBegin (AudioProcessor*, int idx) override
    {
        sendParameterEvent (idx, nullptr, AUParameterAutomationEventTypeTouch);
    }

    void audioProcessorParameterChangeGestureEnd (AudioProcessor*, int idx) override
    {
        sendParameterEvent (idx, nullptr, AUParameterAutomationEventTypeRelease);
    }

    //==============================================================================
    Optional<PositionInfo> getPosition() const override
    {
        PositionInfo info;
        info.setTimeInSamples ((int64) (lastTimeStamp.mSampleTime + 0.5));
        info.setTimeInSeconds (*info.getTimeInSamples() / getAudioProcessor().getSampleRate());

        info.setFrameRate ([this]
        {
            switch (lastTimeStamp.mSMPTETime.mType)
            {
                case kSMPTETimeType2398:        return FrameRate().withBaseRate (24).withPullDown();
                case kSMPTETimeType24:          return FrameRate().withBaseRate (24);
                case kSMPTETimeType25:          return FrameRate().withBaseRate (25);
                case kSMPTETimeType30Drop:      return FrameRate().withBaseRate (30).withDrop();
                case kSMPTETimeType30:          return FrameRate().withBaseRate (30);
                case kSMPTETimeType2997:        return FrameRate().withBaseRate (30).withPullDown();
                case kSMPTETimeType2997Drop:    return FrameRate().withBaseRate (30).withPullDown().withDrop();
                case kSMPTETimeType60:          return FrameRate().withBaseRate (60);
                case kSMPTETimeType60Drop:      return FrameRate().withBaseRate (60).withDrop();
                case kSMPTETimeType5994:        return FrameRate().withBaseRate (60).withPullDown();
                case kSMPTETimeType5994Drop:    return FrameRate().withBaseRate (60).withPullDown().withDrop();
                case kSMPTETimeType50:          return FrameRate().withBaseRate (50);
                default:                        break;
            }

            return FrameRate();
        }());

        double num;
        NSInteger den;
        NSInteger outDeltaSampleOffsetToNextBeat;
        double outCurrentMeasureDownBeat, bpm;
        double ppqPosition;

        if (hostMusicalContextCallback != nullptr)
        {
            AUHostMusicalContextBlock musicalContextCallback = hostMusicalContextCallback;

            if (musicalContextCallback (&bpm, &num, &den, &ppqPosition, &outDeltaSampleOffsetToNextBeat, &outCurrentMeasureDownBeat))
            {
                info.setTimeSignature (TimeSignature { (int) num, (int) den });
                info.setPpqPositionOfLastBarStart (outCurrentMeasureDownBeat);
                info.setBpm (bpm);
                info.setPpqPosition (ppqPosition);
            }
        }

        double outCurrentSampleInTimeLine = 0, outCycleStartBeat = 0, outCycleEndBeat = 0;
        AUHostTransportStateFlags flags;

        if (hostTransportStateCallback != nullptr)
        {
            AUHostTransportStateBlock transportStateCallback = hostTransportStateCallback;

            if (transportStateCallback (&flags, &outCurrentSampleInTimeLine, &outCycleStartBeat, &outCycleEndBeat))
            {
                info.setTimeInSamples  ((int64) (outCurrentSampleInTimeLine + 0.5));
                info.setTimeInSeconds  (*info.getTimeInSamples() / getAudioProcessor().getSampleRate());
                info.setIsPlaying      ((flags & AUHostTransportStateMoving) != 0);
                info.setIsLooping      ((flags & AUHostTransportStateCycling) != 0);
                info.setIsRecording    ((flags & AUHostTransportStateRecording) != 0);
                info.setLoopPoints     (LoopPoints { outCycleStartBeat, outCycleEndBeat });
            }
        }

        if ((lastTimeStamp.mFlags & kAudioTimeStampHostTimeValid) != 0)
            info.setHostTimeNs (timeConversions.hostTimeToNanos (lastTimeStamp.mHostTime));

        return info;
    }

    //==============================================================================
    static void removeEditor (AudioProcessor& processor)
    {
        ScopedLock editorLock (processor.getCallbackLock());

        if (AudioProcessorEditor* editor = processor.getActiveEditor())
        {
            processor.editorBeingDeleted (editor);
            delete editor;
        }
    }

    AUAudioUnit* getAudioUnit() const { return au; }

private:
    struct Class  : public ObjCClass<AUAudioUnit>
    {
        Class() : ObjCClass<AUAudioUnit> ("AUAudioUnit_")
        {
            addIvar<JuceAudioUnitv3*> ("cppObject");

            JUCE_BEGIN_IGNORE_WARNINGS_GCC_LIKE ("-Wundeclared-selector")
            addMethod (@selector (initWithComponentDescription:options:error:juceClass:), [] (id _self,
                                                                                              SEL,
                                                                                              AudioComponentDescription descr,
                                                                                              AudioComponentInstantiationOptions options,
                                                                                              NSError** error,
                                                                                              JuceAudioUnitv3* juceAU)
            {
                AUAudioUnit* self = _self;

                self = ObjCMsgSendSuper<AUAudioUnit, AUAudioUnit*, AudioComponentDescription,
                                        AudioComponentInstantiationOptions, NSError**> (self, @selector(initWithComponentDescription:options:error:), descr, options, error);

                setThis (self, juceAU);
                return self;
            });

            JUCE_END_IGNORE_WARNINGS_GCC_LIKE

            addMethod (@selector (initWithComponentDescription:options:error:), [] (id _self,
                                                                                    SEL,
                                                                                    AudioComponentDescription descr,
                                                                                    AudioComponentInstantiationOptions options,
                                                                                    NSError** error)
            {
                AUAudioUnit* self = _self;

                self = ObjCMsgSendSuper<AUAudioUnit, AUAudioUnit*, AudioComponentDescription,
                                        AudioComponentInstantiationOptions, NSError**> (self, @selector (initWithComponentDescription:options:error:), descr, options, error);

                auto* juceAU = JuceAudioUnitv3::create (self, descr, options, error);

                setThis (self, juceAU);
                return self;
            });

            addMethod (@selector (dealloc), [] (id self, SEL)
            {
                if (! MessageManager::getInstance()->isThisTheMessageThread())
                {
                    WaitableEvent deletionEvent;

                    struct AUDeleter  : public CallbackMessage
                    {
                        AUDeleter (id selfToDelete, WaitableEvent& event)
                            : parentSelf (selfToDelete), parentDeletionEvent (event)
                        {
                        }

                        void messageCallback() override
                        {
                            delete _this (parentSelf);
                            parentDeletionEvent.signal();
                        }

                        id parentSelf;
                        WaitableEvent& parentDeletionEvent;
                    };

                    (new AUDeleter (self, deletionEvent))->post();
                    deletionEvent.wait (-1);
                }
                else
                {
                    delete _this (self);
                }
            });

            //==============================================================================
            addMethod (@selector (reset),                                   [] (id self, SEL)                                                   { return _this (self)->reset(); });

            //==============================================================================
            addMethod (@selector (currentPreset),                           [] (id self, SEL)                                                   { return _this (self)->getCurrentPreset(); });
            addMethod (@selector (setCurrentPreset:),                       [] (id self, SEL, AUAudioUnitPreset* preset)                        { return _this (self)->setCurrentPreset (preset); });
            addMethod (@selector (factoryPresets),                          [] (id self, SEL)                                                   { return _this (self)->getFactoryPresets(); });
            addMethod (@selector (fullState),                               [] (id self, SEL)                                                   { return _this (self)->getFullState(); });
            addMethod (@selector (setFullState:),                           [] (id self, SEL, NSDictionary<NSString *, id>* state)              { return _this (self)->setFullState (state); });
            addMethod (@selector (parameterTree),                           [] (id self, SEL)                                                   { return _this (self)->getParameterTree(); });
            addMethod (@selector (parametersForOverviewWithCount:),         [] (id self, SEL, NSInteger count)                                  { return _this (self)->parametersForOverviewWithCount (static_cast<int> (count)); });

            //==============================================================================
            addMethod (@selector (latency),                                 [] (id self, SEL)                                                   { return _this (self)->getLatency(); });
            addMethod (@selector (tailTime),                                [] (id self, SEL)                                                   { return _this (self)->getTailTime(); });

            //==============================================================================
            addMethod (@selector (inputBusses),                             [] (id self, SEL)                                                   { return _this (self)->getInputBusses(); });
            addMethod (@selector (outputBusses),                            [] (id self, SEL)                                                   { return _this (self)->getOutputBusses(); });
            addMethod (@selector (channelCapabilities),                     [] (id self, SEL)                                                   { return _this (self)->getChannelCapabilities(); });
            addMethod (@selector (shouldChangeToFormat:forBus:),            [] (id self, SEL, AVAudioFormat* format, AUAudioUnitBus* bus)       { return _this (self)->shouldChangeToFormat (format, bus) ? YES : NO; });

            //==============================================================================
            addMethod (@selector (virtualMIDICableCount),                   [] (id self, SEL)                                                   { return _this (self)->getVirtualMIDICableCount(); });

            JUCE_BEGIN_IGNORE_WARNINGS_GCC_LIKE ("-Wundeclared-selector")
            addMethod (@selector (supportsMPE),                             [] (id self, SEL)                                                   { return _this (self)->getSupportsMPE() ? YES : NO; });
            JUCE_END_IGNORE_WARNINGS_GCC_LIKE

            if (@available (macOS 10.13, iOS 11.0, *))
                addMethod (@selector (MIDIOutputNames),                     [] (id self, SEL)                                                   { return _this (self)->getMIDIOutputNames(); });

            //==============================================================================
            addMethod (@selector (internalRenderBlock),                     [] (id self, SEL)                                                   { return _this (self)->getInternalRenderBlock(); });
            addMethod (@selector (canProcessInPlace),                       [] (id,      SEL)                                                   { return NO; });
            addMethod (@selector (isRenderingOffline),                      [] (id self, SEL)                                                   { return _this (self)->getRenderingOffline() ? YES : NO; });
            addMethod (@selector (setRenderingOffline:),                    [] (id self, SEL, BOOL renderingOffline)                            { return _this (self)->setRenderingOffline (renderingOffline); });
            addMethod (@selector (shouldBypassEffect),                      [] (id self, SEL)                                                   { return _this (self)->getShouldBypassEffect() ? YES : NO; });
            addMethod (@selector (setShouldBypassEffect:),                  [] (id self, SEL, BOOL shouldBypass)                                { return _this (self)->setShouldBypassEffect (shouldBypass); });
            addMethod (@selector (allocateRenderResourcesAndReturnError:),  [] (id self, SEL, NSError** error)                                  { return _this (self)->allocateRenderResourcesAndReturnError (error) ? YES : NO; });
            addMethod (@selector (deallocateRenderResources),               [] (id self, SEL)                                                   { return _this (self)->deallocateRenderResources(); });

            //==============================================================================
            addMethod (@selector (contextName),                             [] (id self, SEL)                                                   { return _this (self)->getContextName(); });
            addMethod (@selector (setContextName:),                         [](id self, SEL, NSString* str)                                     { return _this (self)->setContextName (str); });

            //==============================================================================
            if (@available (macOS 10.13, iOS 11.0, *))
            {
                addMethod (@selector (supportedViewConfigurations:), [] (id self, SEL, NSArray<AUAudioUnitViewConfiguration*>* configs)
                {
                    auto supportedViewIndices = [[NSMutableIndexSet alloc] init];
                    auto n = [configs count];

                    if (auto* editor = _this (self)->getAudioProcessor().createEditorIfNeeded())
                    {
                        // If you hit this assertion then your plug-in's editor is reporting that it doesn't support
                        // any host MIDI controller configurations!
                        jassert (editor->supportsHostMIDIControllerPresence (true) || editor->supportsHostMIDIControllerPresence (false));

                        for (auto i = 0u; i < n; ++i)
                        {
                            if (auto viewConfiguration = [configs objectAtIndex: i])
                            {
                                if (editor->supportsHostMIDIControllerPresence ([viewConfiguration hostHasController] == YES))
                                {
                                    auto* constrainer = editor->getConstrainer();
                                    auto height = (int) [viewConfiguration height];
                                    auto width  = (int) [viewConfiguration width];

                                    const auto maxLimits = std::numeric_limits<int>::max() / 2;
                                    const Rectangle<int> requestedBounds { width, height };
                                    auto modifiedBounds = requestedBounds;
                                    constrainer->checkBounds (modifiedBounds, editor->getBounds().withZeroOrigin(), { maxLimits, maxLimits }, false, false, false, false);

                                    if (modifiedBounds == requestedBounds)
                                        [supportedViewIndices addIndex: i];
                                }
                            }
                        }
                    }

                    return [supportedViewIndices autorelease];
                });

                addMethod (@selector (selectViewConfiguration:), [] (id self, SEL, AUAudioUnitViewConfiguration* config)
                {
                    _this (self)->processorHolder->viewConfiguration.reset (new AudioProcessorHolder::ViewConfig { [config width], [config height], [config hostHasController] == YES });
                });
            }

            registerClass();
        }

        //==============================================================================
        static JuceAudioUnitv3* _this (id self)                     { return getIvar<JuceAudioUnitv3*>     (self, "cppObject"); }
        static void setThis (id self, JuceAudioUnitv3* cpp)         { object_setInstanceVariable           (self, "cppObject", cpp); }
    };

    static JuceAudioUnitv3* create (AUAudioUnit* audioUnit, AudioComponentDescription descr, AudioComponentInstantiationOptions options, NSError** error)
    {
        PluginHostType::jucePlugInClientCurrentWrapperType = AudioProcessor::wrapperType_AudioUnitv3;
        return new JuceAudioUnitv3 (audioUnit, descr, options, error);
    }

    //==============================================================================
    static Class& getClass()
    {
        static Class result;
        return result;
    }

    //==============================================================================
    struct BusBuffer
    {
        BusBuffer (AUAudioUnitBus* bus, int maxFramesPerBuffer)
            : auBus (bus),
              maxFrames (maxFramesPerBuffer),
              numberOfChannels (static_cast<int> ([[auBus format] channelCount])),
              isInterleaved ([[auBus format] isInterleaved])
        {
            alloc();
        }

        //==============================================================================
        void alloc()
        {
            const int numBuffers = isInterleaved ? 1 : numberOfChannels;
            int bytes = static_cast<int> (sizeof (AudioBufferList))
                          + ((numBuffers - 1) * static_cast<int> (sizeof (::AudioBuffer)));
            jassert (bytes > 0);

            bufferListStorage.calloc (static_cast<size_t> (bytes));
            bufferList = reinterpret_cast<AudioBufferList*> (bufferListStorage.getData());

            const int bufferChannels = isInterleaved ? numberOfChannels : 1;
            scratchBuffer.setSize (numBuffers, bufferChannels * maxFrames);
        }

        void dealloc()
        {
            bufferList = nullptr;
            bufferListStorage.free();
            scratchBuffer.setSize (0, 0);
        }

        //==============================================================================
        int numChannels() const noexcept                { return numberOfChannels; }
        bool interleaved() const noexcept               { return isInterleaved; }
        AudioBufferList* get() const noexcept           { return bufferList; }

        //==============================================================================
        void prepare (UInt32 nFrames, const AudioBufferList* other = nullptr) noexcept
        {
            const int numBuffers = isInterleaved ? 1 : numberOfChannels;
            const bool isCompatible = isCompatibleWith (other);

            bufferList->mNumberBuffers = static_cast<UInt32> (numBuffers);

            for (int i = 0; i < numBuffers; ++i)
            {
                const UInt32 bufferChannels = static_cast<UInt32> (isInterleaved ? numberOfChannels : 1);
                bufferList->mBuffers[i].mNumberChannels = bufferChannels;
                bufferList->mBuffers[i].mData = (isCompatible ? other->mBuffers[i].mData
                                                              : scratchBuffer.getWritePointer (i));
                bufferList->mBuffers[i].mDataByteSize = nFrames * bufferChannels * sizeof (float);
            }
        }

        //==============================================================================
        bool isCompatibleWith (const AudioBufferList* other) const noexcept
        {
            if (other == nullptr)
                return false;

            if (other->mNumberBuffers > 0)
            {
                const bool otherInterleaved = AudioUnitHelpers::isAudioBufferInterleaved (*other);
                const int otherChannels = static_cast<int> (otherInterleaved ? other->mBuffers[0].mNumberChannels
                                                                             : other->mNumberBuffers);

                return otherInterleaved == isInterleaved
                    && numberOfChannels == otherChannels;
            }

            return numberOfChannels == 0;
        }

    private:
        AUAudioUnitBus* auBus;
        HeapBlock<char> bufferListStorage;
        AudioBufferList* bufferList = nullptr;
        int maxFrames, numberOfChannels;
        bool isInterleaved;
        juce::AudioBuffer<float> scratchBuffer;
    };

    class FactoryPresets
    {
    public:
        using Presets = std::unique_ptr<NSMutableArray<AUAudioUnitPreset*>, NSObjectDeleter>;

        void set (Presets newPresets)
        {
            std::lock_guard<std::mutex> lock (mutex);
            std::swap (presets, newPresets);
        }

        NSArray* get() const
        {
            std::lock_guard<std::mutex> lock (mutex);
            return presets.get();
        }

        AUAudioUnitPreset* getAtIndex (int index) const
        {
            std::lock_guard<std::mutex> lock (mutex);

            if (index < (int) [presets.get() count])
                return [presets.get() objectAtIndex: (unsigned int) index];

            return nullptr;
        }

    private:
        Presets presets;
        mutable std::mutex mutex;
    };

    //==============================================================================
    void addAudioUnitBusses (bool isInput)
    {
        std::unique_ptr<NSMutableArray<AUAudioUnitBus*>, NSObjectDeleter> array ([[NSMutableArray<AUAudioUnitBus*> alloc] init]);
        AudioProcessor& processor = getAudioProcessor();
        const auto numWrapperBuses = AudioUnitHelpers::getBusCountForWrapper (processor, isInput);
        const auto numProcessorBuses = AudioUnitHelpers::getBusCount (processor, isInput);

        for (int i = 0; i < numWrapperBuses; ++i)
        {
            using AVAudioFormatPtr = std::unique_ptr<AVAudioFormat, NSObjectDeleter>;

            const auto audioFormat = [&]() -> AVAudioFormatPtr
            {
                const auto tag = i < numProcessorBuses ? CoreAudioLayouts::toCoreAudio (processor.getChannelLayoutOfBus (isInput, i))
                                                       : kAudioChannelLayoutTag_Stereo;
                const std::unique_ptr<AVAudioChannelLayout, NSObjectDeleter> layout { [[AVAudioChannelLayout alloc] initWithLayoutTag: tag] };

                if (auto format = AVAudioFormatPtr { [[AVAudioFormat alloc] initStandardFormatWithSampleRate: kDefaultSampleRate
                                                                                               channelLayout: layout.get()] })
                    return format;

                const auto channels = i < numProcessorBuses ? processor.getChannelCountOfBus (isInput, i)
                                                            : 2;

                // According to the docs, this will fail if the number of channels is greater than 2.
                if (auto format = AVAudioFormatPtr { [[AVAudioFormat alloc] initStandardFormatWithSampleRate: kDefaultSampleRate
                                                                                                    channels: static_cast<AVAudioChannelCount> (channels)] })
                    return format;

                jassertfalse;
                return nullptr;
            }();

            using AUAudioUnitBusPtr = std::unique_ptr<AUAudioUnitBus, NSObjectDeleter>;

            const auto audioUnitBus = [&]() -> AUAudioUnitBusPtr
            {
                if (audioFormat != nullptr)
                    return AUAudioUnitBusPtr { [[AUAudioUnitBus alloc] initWithFormat: audioFormat.get() error: nullptr] };

                jassertfalse;
                return nullptr;
            }();

            if (audioUnitBus != nullptr)
                [array.get() addObject: audioUnitBus.get()];
        }

        (isInput ? inputBusses : outputBusses).reset ([[AUAudioUnitBusArray alloc] initWithAudioUnit: au
                                                                                             busType: (isInput ? AUAudioUnitBusTypeInput : AUAudioUnitBusTypeOutput)
                                                                                              busses: array.get()]);
    }

    // When parameters are discrete we need to use integer values.
    float getMaximumParameterValue (AudioProcessorParameter* juceParam) const
    {
       #if JUCE_FORCE_LEGACY_PARAMETER_AUTOMATION_TYPE
        ignoreUnused (juceParam);
        return 1.0f;
       #else
        return juceParam->isDiscrete() ? (float) (juceParam->getNumSteps() - 1) : 1.0f;
       #endif
    }

    std::unique_ptr<AUParameter, NSObjectDeleter> createParameter (AudioProcessorParameter* parameter)
    {
        const String name (parameter->getName (512));

        AudioUnitParameterUnit unit = kAudioUnitParameterUnit_Generic;
        AudioUnitParameterOptions flags = (UInt32) (kAudioUnitParameterFlag_IsWritable
                                                  | kAudioUnitParameterFlag_IsReadable
                                                  | kAudioUnitParameterFlag_HasCFNameString
                                                  | kAudioUnitParameterFlag_ValuesHaveStrings);

       #if ! JUCE_FORCE_LEGACY_PARAMETER_AUTOMATION_TYPE
        flags |= (UInt32) kAudioUnitParameterFlag_IsHighResolution;
       #endif

        // Set whether the param is automatable (unnamed parameters aren't allowed to be automated).
        if (name.isEmpty() || ! parameter->isAutomatable())
            flags |= kAudioUnitParameterFlag_NonRealTime;

        const bool isParameterDiscrete = parameter->isDiscrete();

        if (! isParameterDiscrete)
            flags |= kAudioUnitParameterFlag_CanRamp;

        if (parameter->isMetaParameter())
            flags |= kAudioUnitParameterFlag_IsGlobalMeta;

        std::unique_ptr<NSMutableArray, NSObjectDeleter> valueStrings;

        // Is this a meter?
        if (((parameter->getCategory() & 0xffff0000) >> 16) == 2)
        {
            flags &= ~kAudioUnitParameterFlag_IsWritable;
            flags |= kAudioUnitParameterFlag_MeterReadOnly | kAudioUnitParameterFlag_DisplayLogarithmic;
            unit = kAudioUnitParameterUnit_LinearGain;
        }
        else
        {
           #if ! JUCE_FORCE_LEGACY_PARAMETER_AUTOMATION_TYPE
            if (parameter->isDiscrete())
            {
                unit = parameter->isBoolean() ? kAudioUnitParameterUnit_Boolean : kAudioUnitParameterUnit_Indexed;
                auto maxValue = getMaximumParameterValue (parameter);
                auto numSteps = parameter->getNumSteps();

                // Some hosts can't handle the huge numbers of discrete parameter values created when
                // using the default number of steps.
                jassert (numSteps != AudioProcessor::getDefaultNumParameterSteps());

                valueStrings.reset ([NSMutableArray new]);

                for (int i = 0; i < numSteps; ++i)
                    [valueStrings.get() addObject: juceStringToNS (parameter->getText ((float) i / maxValue, 0))];
            }
           #endif
        }

        AUParameterAddress address = generateAUParameterAddress (parameter);

       #if ! JUCE_FORCE_USE_LEGACY_PARAM_IDS
        // If you hit this assertion then you have either put a parameter in two groups or you are
        // very unlucky and the hash codes of your parameter ids are not unique.
        jassert (! paramMap.contains (static_cast<int64> (address)));

        paramAddresses.add (address);
        paramMap.set (static_cast<int64> (address), parameter->getParameterIndex());
       #endif

        auto getParameterIdentifier = [parameter]
        {
            if (auto* paramWithID = dynamic_cast<AudioProcessorParameterWithID*> (parameter))
                return paramWithID->paramID;

            // This could clash if any groups have been given integer IDs!
            return String (parameter->getParameterIndex());
        };

        std::unique_ptr<AUParameter, NSObjectDeleter> param;

        @try
        {
            // Create methods in AUParameterTree return unretained objects (!) -> see Apple header AUAudioUnitImplementation.h
            param.reset([[AUParameterTree createParameterWithIdentifier: juceStringToNS (getParameterIdentifier())
                                                                   name: juceStringToNS (name)
                                                                address: address
                                                                    min: 0.0f
                                                                    max: getMaximumParameterValue (parameter)
                                                                   unit: unit
                                                               unitName: nullptr
                                                                  flags: flags
                                                           valueStrings: valueStrings.get()
                                                    dependentParameters: nullptr]
                         retain]);
        }

        @catch (NSException* exception)
        {
            // Do you have duplicate identifiers in any of your groups or parameters,
            // or do your identifiers have unusual characters in them?
            jassertfalse;
        }

        [param.get() setValue: parameter->getDefaultValue()];

        [overviewParams.get() addObject: [NSNumber numberWithUnsignedLongLong: address]];

        return param;
    }

    std::unique_ptr<AUParameterGroup, NSObjectDeleter> createParameterGroup (AudioProcessorParameterGroup* group)
    {
        std::unique_ptr<NSMutableArray<AUParameterNode*>, NSObjectDeleter> children ([NSMutableArray<AUParameterNode*> new]);

        for (auto* node : *group)
        {
            if (auto* childGroup = node->getGroup())
                [children.get() addObject: createParameterGroup (childGroup).get()];
            else
                [children.get() addObject: createParameter (node->getParameter()).get()];
        }

        std::unique_ptr<AUParameterGroup, NSObjectDeleter> result;

        @try
        {
            // Create methods in AUParameterTree return unretained objects (!) -> see Apple header AUAudioUnitImplementation.h
            result.reset ([[AUParameterTree createGroupWithIdentifier: juceStringToNS (group->getID())
                                                                 name: juceStringToNS (group->getName())
                                                             children: children.get()]
                           retain]);
        }

        @catch (NSException* exception)
        {
            // Do you have duplicate identifiers in any of your groups or parameters,
            // or do your identifiers have unusual characters in them?
            jassertfalse;
        }

        return result;
    }

    void addParameters()
    {
        auto& processor = getAudioProcessor();
        juceParameters.update (processor, forceLegacyParamIDs);

        // This is updated when we build the tree.
        overviewParams.reset ([NSMutableArray<NSNumber*> new]);

        std::unique_ptr<NSMutableArray<AUParameterNode*>, NSObjectDeleter> topLevelNodes ([NSMutableArray<AUParameterNode*> new]);

        for (auto* node : processor.getParameterTree())
            if (auto* childGroup = node->getGroup())
                [topLevelNodes.get() addObject: createParameterGroup (childGroup).get()];
            else
                [topLevelNodes.get() addObject: createParameter (node->getParameter()).get()];

        @try
        {
            // Create methods in AUParameterTree return unretained objects (!) -> see Apple header AUAudioUnitImplementation.h
            paramTree.reset ([[AUParameterTree createTreeWithChildren: topLevelNodes.get()] retain]);
        }

        @catch (NSException* exception)
        {
            // Do you have duplicate identifiers in any of your groups or parameters,
            // or do your identifiers have unusual characters in them?
            jassertfalse;
        }

        paramObserver           = CreateObjCBlock (this, &JuceAudioUnitv3::valueChangedFromHost);
        paramProvider           = CreateObjCBlock (this, &JuceAudioUnitv3::getValue);
        stringFromValueProvider = CreateObjCBlock (this, &JuceAudioUnitv3::stringFromValue);
        valueFromStringProvider = CreateObjCBlock (this, &JuceAudioUnitv3::valueFromString);

        [paramTree.get() setImplementorValueObserver: paramObserver];
        [paramTree.get() setImplementorValueProvider: paramProvider];
        [paramTree.get() setImplementorStringFromValueCallback: stringFromValueProvider];
        [paramTree.get() setImplementorValueFromStringCallback: valueFromStringProvider];

        if (processor.hasEditor())
        {
            editorParamObserver = CreateObjCBlock (this, &JuceAudioUnitv3::valueChangedForObserver);
            editorObserverToken = [paramTree.get() tokenByAddingParameterObserver: editorParamObserver];
        }

        if ((bypassParam = processor.getBypassParameter()) != nullptr)
            bypassParam->addListener (this);
    }

    void setAudioProcessorParameter (AudioProcessorParameter* juceParam, float value)
    {
        if (value != juceParam->getValue())
        {
            juceParam->setValue (value);

            inParameterChangedCallback = true;
            juceParam->sendValueChangedMessageToListeners (value);
        }
    }

    void addPresets()
    {
        FactoryPresets::Presets newPresets { [[NSMutableArray<AUAudioUnitPreset*> alloc] init] };

        const int n = getAudioProcessor().getNumPrograms();

        for (int idx = 0; idx < n; ++idx)
        {
            String name = getAudioProcessor().getProgramName (idx);

            std::unique_ptr<AUAudioUnitPreset, NSObjectDeleter> preset ([[AUAudioUnitPreset alloc] init]);
            [preset.get() setName: juceStringToNS (name)];
            [preset.get() setNumber: static_cast<NSInteger> (idx)];

            [newPresets.get() addObject: preset.get()];
        }

        factoryPresets.set (std::move (newPresets));
    }

    //==============================================================================
    void allocateBusBuffer (bool isInput)
    {
        OwnedArray<BusBuffer>& busBuffers = isInput ? inBusBuffers : outBusBuffers;
        busBuffers.clear();

        const int n = AudioUnitHelpers::getBusCountForWrapper (getAudioProcessor(), isInput);
        const AUAudioFrameCount maxFrames = [au maximumFramesToRender];

        for (int busIdx = 0; busIdx < n; ++busIdx)
            busBuffers.add (new BusBuffer ([(isInput ? inputBusses.get() : outputBusses.get()) objectAtIndexedSubscript: static_cast<unsigned int> (busIdx)],
                                           static_cast<int> (maxFrames)));
    }

    //==============================================================================
    void processEvents (const AURenderEvent *__nullable realtimeEventListHead, int numParams, AUEventSampleTime startTime)
    {
        ignoreUnused (numParams);

        for (const AURenderEvent* event = realtimeEventListHead; event != nullptr; event = event->head.next)
        {
            switch (event->head.eventType)
            {
                case AURenderEventMIDI:
                {
                    const AUMIDIEvent& midiEvent = event->MIDI;
                    midiMessages.addEvent (midiEvent.data, midiEvent.length, static_cast<int> (midiEvent.eventSampleTime - startTime));
                }
                break;

               #if JUCE_AUV3_MIDI_EVENT_LIST_SUPPORTED
                case AURenderEventMIDIEventList:
                {
                    const auto& list = event->MIDIEventsList.eventList;
                    auto* packet = &list.packet[0];

                    for (uint32_t i = 0; i < list.numPackets; ++i)
                    {
                        converter.dispatch (reinterpret_cast<const uint32_t*> (packet->words),
                                            reinterpret_cast<const uint32_t*> (packet->words + packet->wordCount),
                                            static_cast<int> (packet->timeStamp - (MIDITimeStamp) startTime),
                                            [this] (const MidiMessage& message) { midiMessages.addEvent (message, int (message.getTimeStamp())); });

                        packet = MIDIEventPacketNext (packet);
                    }
                }
                break;
               #endif

                case AURenderEventParameter:
                case AURenderEventParameterRamp:
                {
                    const AUParameterEvent& paramEvent = event->parameter;

                    if (auto* p = getJuceParameterForAUAddress (paramEvent.parameterAddress))
                    {
                        auto normalisedValue = paramEvent.value / getMaximumParameterValue (p);
                        setAudioProcessorParameter (p, normalisedValue);
                    }
                }
                break;

                case AURenderEventMIDISysEx:
                default:
                    break;
            }
        }
    }

    AUAudioUnitStatus renderCallback (AudioUnitRenderActionFlags* actionFlags, const AudioTimeStamp* timestamp, AUAudioFrameCount frameCount,
                                      NSInteger outputBusNumber, AudioBufferList* outputData, const AURenderEvent *__nullable realtimeEventListHead,
                                      AURenderPullInputBlock __nullable pullInputBlock)
    {
        auto& processor = getAudioProcessor();
        jassert (static_cast<int> (frameCount) <= getAudioProcessor().getBlockSize());

        const auto numProcessorBusesOut = AudioUnitHelpers::getBusCount (processor, false);

        if (lastTimeStamp.mSampleTime != timestamp->mSampleTime)
        {
            // process params and incoming midi (only once for a given timestamp)
            midiMessages.clear();

            const int numParams = juceParameters.getNumParameters();
            processEvents (realtimeEventListHead, numParams, static_cast<AUEventSampleTime> (timestamp->mSampleTime));

            lastTimeStamp = *timestamp;

            const auto numWrapperBusesIn    = AudioUnitHelpers::getBusCountForWrapper (processor, true);
            const auto numWrapperBusesOut   = AudioUnitHelpers::getBusCountForWrapper (processor, false);
            const auto numProcessorBusesIn  = AudioUnitHelpers::getBusCount (processor, true);

            // prepare buffers
            {
                for (int busIdx = 0; busIdx < numWrapperBusesOut; ++busIdx)
                {
                     BusBuffer& busBuffer = *outBusBuffers[busIdx];
                     const bool canUseDirectOutput =
                         (busIdx == outputBusNumber && outputData != nullptr && outputData->mNumberBuffers > 0);

                    busBuffer.prepare (frameCount, canUseDirectOutput ? outputData : nullptr);

                    if (numProcessorBusesOut <= busIdx)
                        AudioUnitHelpers::clearAudioBuffer (*busBuffer.get());
                }

                for (int busIdx = 0; busIdx < numWrapperBusesIn; ++busIdx)
                {
                    BusBuffer& busBuffer = *inBusBuffers[busIdx];
                    busBuffer.prepare (frameCount, busIdx < numWrapperBusesOut ? outBusBuffers[busIdx]->get() : nullptr);
                }

                audioBuffer.reset();
            }

            // pull inputs
            {
                for (int busIdx = 0; busIdx < numProcessorBusesIn; ++busIdx)
                {
                    BusBuffer& busBuffer = *inBusBuffers[busIdx];
                    AudioBufferList* buffer = busBuffer.get();

                    if (pullInputBlock == nullptr || pullInputBlock (actionFlags, timestamp, frameCount, busIdx, buffer) != noErr)
                        AudioUnitHelpers::clearAudioBuffer (*buffer);

                    if (actionFlags != nullptr && (*actionFlags & kAudioUnitRenderAction_OutputIsSilence) != 0)
                        AudioUnitHelpers::clearAudioBuffer (*buffer);
                }
            }

            // set buffer pointer to minimize copying
            {
                int chIdx = 0;

                for (int busIdx = 0; busIdx < numProcessorBusesOut; ++busIdx)
                {
                    BusBuffer& busBuffer = *outBusBuffers[busIdx];
                    AudioBufferList* buffer = busBuffer.get();

                    const bool interleaved = busBuffer.interleaved();
                    const int numChannels = busBuffer.numChannels();

                    const int* outLayoutMap = mapper.get (false, busIdx);

                    for (int ch = 0; ch < numChannels; ++ch)
                        audioBuffer.setBuffer (chIdx++, interleaved ? nullptr : static_cast<float*> (buffer->mBuffers[outLayoutMap[ch]].mData));
                }

                // use input pointers on remaining channels

                for (int busIdx = 0; chIdx < totalInChannels;)
                {
                    const int channelOffset = processor.getOffsetInBusBufferForAbsoluteChannelIndex (true, chIdx, busIdx);

                    BusBuffer& busBuffer = *inBusBuffers[busIdx];
                    AudioBufferList* buffer = busBuffer.get();

                    const int* inLayoutMap = mapper.get (true, busIdx);
                    audioBuffer.setBuffer (chIdx++, busBuffer.interleaved() ? nullptr : static_cast<float*> (buffer->mBuffers[inLayoutMap[channelOffset]].mData));
                }
            }

            // copy input
            {
                for (int busIdx = 0; busIdx < numProcessorBusesIn; ++busIdx)
                    audioBuffer.set (busIdx, *inBusBuffers[busIdx]->get(), mapper.get (true, busIdx));

                audioBuffer.clearUnusedChannels ((int) frameCount);
            }

            // process audio
            processBlock (audioBuffer.getBuffer (frameCount), midiMessages);

            // send MIDI
           #if JucePlugin_ProducesMidiOutput
            if (@available (macOS 10.13, iOS 11.0, *))
            {
                if (auto midiOut = midiOutputEventBlock)
                    for (const auto metadata : midiMessages)
                        if (isPositiveAndBelow (metadata.samplePosition, frameCount))
                            midiOut ((int64_t) metadata.samplePosition + (int64_t) (timestamp->mSampleTime + 0.5),
                                     0,
                                     metadata.numBytes,
                                     metadata.data);
            }
           #endif
        }
        //else {
        //    // now copy the next bus data to the other output buffer
        //    audioBuffer.pop (*outputData,
        //                     mapper.get (false, (int) outputBusNumber));
        //}


        // copy back
        if (outputBusNumber < numProcessorBusesOut && outputData != nullptr)
            audioBuffer.get ((int) outputBusNumber, *outputData, mapper.get (false, (int) outputBusNumber));

        return noErr;
    }

    void processBlock (juce::AudioBuffer<float>& buffer, MidiBuffer& midiBuffer) noexcept
    {
        auto& processor = getAudioProcessor();
        const ScopedLock sl (processor.getCallbackLock());

        if (processor.isSuspended())
            buffer.clear();
        else if (bypassParam == nullptr && [au shouldBypassEffect])
            processor.processBlockBypassed (buffer, midiBuffer);
        else
            processor.processBlock (buffer, midiBuffer);
    }

    //==============================================================================
    void valueChangedFromHost (AUParameter* param, AUValue value)
    {
        if (param != nullptr)
        {
            if (auto* p = getJuceParameterForAUAddress ([param address]))
            {
                auto normalisedValue = value / getMaximumParameterValue (p);
                setAudioProcessorParameter (p, normalisedValue);
            }
        }
    }

    AUValue getValue (AUParameter* param) const
    {
        if (param != nullptr)
        {
            if (auto* p = getJuceParameterForAUAddress ([param address]))
                return p->getValue() * getMaximumParameterValue (p);
        }

        return 0;
    }

    void valueChangedForObserver (AUParameterAddress, AUValue)
    {
        // this will have already been handled by valueChangedFromHost
    }

    NSString* stringFromValue (AUParameter* param, const AUValue* value)
    {
        String text;

        if (param != nullptr && value != nullptr)
        {
            if (auto* p = getJuceParameterForAUAddress ([param address]))
            {
                if (LegacyAudioParameter::isLegacy (p))
                    text = String (*value);
                else
                    text = p->getText (*value / getMaximumParameterValue (p), 0);
            }
        }

        return juceStringToNS (text);
    }

    AUValue valueFromString (AUParameter* param, NSString* str)
    {
        if (param != nullptr && str != nullptr)
        {
            if (auto* p = getJuceParameterForAUAddress ([param address]))
            {
                const String text (nsStringToJuce (str));

                if (LegacyAudioParameter::isLegacy (p))
                    return text.getFloatValue();
                else
                    return p->getValueForText (text) * getMaximumParameterValue (p);
            }
        }

        return 0;
    }

    //==============================================================================
    // this is only ever called for the bypass parameter
    void parameterValueChanged (int, float newValue) override
    {
        JuceAudioUnitv3::setShouldBypassEffect (newValue != 0.0f);
    }

    void parameterGestureChanged (int, bool) override {}

    //==============================================================================
    inline AUParameterAddress getAUParameterAddressForIndex (int paramIndex) const noexcept
    {
       #if JUCE_FORCE_USE_LEGACY_PARAM_IDS
        return static_cast<AUParameterAddress> (paramIndex);
       #else
        return paramAddresses.getReference (paramIndex);
       #endif
    }

    inline int getJuceParameterIndexForAUAddress (AUParameterAddress address) const noexcept
    {
       #if JUCE_FORCE_USE_LEGACY_PARAM_IDS
        return static_cast<int> (address);
       #else
        return paramMap[static_cast<int64> (address)];
       #endif
    }

    AUParameterAddress generateAUParameterAddress (AudioProcessorParameter* param) const
    {
        const String& juceParamID = LegacyAudioParameter::getParamID (param, forceLegacyParamIDs);

        return static_cast<AUParameterAddress> (forceLegacyParamIDs ? juceParamID.getIntValue()
                                                                    : juceParamID.hashCode64());
    }

    AudioProcessorParameter* getJuceParameterForAUAddress (AUParameterAddress address) const noexcept
    {
        return juceParameters.getParamForIndex (getJuceParameterIndexForAUAddress (address));
    }

    //==============================================================================
    static constexpr double kDefaultSampleRate = 44100.0;

    AUAudioUnit* au;
    AudioProcessorHolder::Ptr processorHolder;

    int totalInChannels, totalOutChannels;

    CoreAudioTimeConversions timeConversions;
    std::unique_ptr<AUAudioUnitBusArray, NSObjectDeleter> inputBusses, outputBusses;

    ObjCBlock<AUImplementorValueObserver> paramObserver;
    ObjCBlock<AUImplementorValueProvider> paramProvider;
    ObjCBlock<AUImplementorStringFromValueCallback> stringFromValueProvider;
    ObjCBlock<AUImplementorValueFromStringCallback> valueFromStringProvider;

   #if ! JUCE_FORCE_USE_LEGACY_PARAM_IDS
    Array<AUParameterAddress> paramAddresses;
    HashMap<int64, int> paramMap;
   #endif
    LegacyAudioParametersWrapper juceParameters;

    // to avoid recursion on parameter changes, we need to add an
    // editor observer to do the parameter changes
    ObjCBlock<AUParameterObserver> editorParamObserver;
    AUParameterObserverToken editorObserverToken;

    std::unique_ptr<AUParameterTree, NSObjectDeleter> paramTree;
    std::unique_ptr<NSMutableArray<NSNumber*>, NSObjectDeleter> overviewParams, channelCapabilities;

    FactoryPresets factoryPresets;

    ObjCBlock<AUInternalRenderBlock> internalRenderBlock;

    AudioUnitHelpers::CoreAudioBufferList audioBuffer;
    AudioUnitHelpers::ChannelRemapper mapper;

    OwnedArray<BusBuffer> inBusBuffers, outBusBuffers;
    MidiBuffer midiMessages;
    AUMIDIOutputEventBlock midiOutputEventBlock = nullptr;

   #if JUCE_AUV3_MIDI_EVENT_LIST_SUPPORTED
    ump::ToBytestreamDispatcher converter { 2048 };
   #endif

    ObjCBlock<AUHostMusicalContextBlock> hostMusicalContextCallback;
    ObjCBlock<AUHostTransportStateBlock> hostTransportStateCallback;

    AudioTimeStamp lastTimeStamp;

    String contextName;

    ThreadLocalValue<bool> inParameterChangedCallback;
   #if JUCE_FORCE_USE_LEGACY_PARAM_IDS
    static constexpr bool forceLegacyParamIDs = true;
   #else
    static constexpr bool forceLegacyParamIDs = false;
   #endif
    AudioProcessorParameter* bypassParam = nullptr;
};

#if JUCE_IOS
namespace juce
{
struct UIViewPeerControllerReceiver
{
    virtual ~UIViewPeerControllerReceiver();
    virtual void setViewController (UIViewController*) = 0;
};
}
#endif

//==============================================================================
class JuceAUViewController
{
public:
    JuceAUViewController (AUViewController<AUAudioUnitFactory>* p)
        : myself (p)
    {
        PluginHostType::jucePlugInClientCurrentWrapperType = AudioProcessor::wrapperType_AudioUnitv3;
        initialiseJuce_GUI();
    }

    ~JuceAUViewController()
    {
        JUCE_ASSERT_MESSAGE_THREAD

        if (processorHolder.get() != nullptr)
            JuceAudioUnitv3::removeEditor (getAudioProcessor());
    }

    //==============================================================================
    void loadView()
    {
        JUCE_ASSERT_MESSAGE_THREAD

        if (AudioProcessor* p = createPluginFilterOfType (AudioProcessor::wrapperType_AudioUnitv3))
        {
            processorHolder = new AudioProcessorHolder (p);
            auto& processor = getAudioProcessor();

            if (processor.hasEditor())
            {
                if (AudioProcessorEditor* editor = processor.createEditorIfNeeded())
                {
                    preferredSize = editor->getBounds();

                    JUCE_IOS_MAC_VIEW* view = [[[JUCE_IOS_MAC_VIEW alloc] initWithFrame: convertToCGRect (editor->getBounds())] autorelease];
                    [myself setView: view];

                   #if JUCE_IOS
                    editor->setVisible (false);
                   #else
                    editor->setVisible (true);
                   #endif

                    editor->addToDesktop (0, view);

                   #if JUCE_IOS
                    if (JUCE_IOS_MAC_VIEW* peerView = [[[myself view] subviews] objectAtIndex: 0])
                        [peerView setContentMode: UIViewContentModeTop];

                    if (auto* peer = dynamic_cast<UIViewPeerControllerReceiver*> (editor->getPeer()))
                        peer->setViewController (myself);
                   #endif
                }
            }
        }
    }

    void viewDidLayoutSubviews()
    {
        if (auto holder = processorHolder.get())
        {
            if ([myself view] != nullptr)
            {
                if (AudioProcessorEditor* editor = getAudioProcessor().getActiveEditor())
                {
                    if (holder->viewConfiguration != nullptr)
                        editor->hostMIDIControllerIsAvailable (holder->viewConfiguration->hostHasMIDIController);

                    editor->setBounds (convertToRectInt ([[myself view] bounds]));

                    if (JUCE_IOS_MAC_VIEW* peerView = [[[myself view] subviews] objectAtIndex: 0])
                    {
                       #if JUCE_IOS
                        [peerView setNeedsDisplay];
                       #else
                        [peerView setNeedsDisplay: YES];
                       #endif
                    }
                }
            }
        }
    }

    void didReceiveMemoryWarning()
    {
        if (auto ptr = processorHolder.get())
            if (auto* processor = ptr->get())
                processor->memoryWarningReceived();
    }

    void viewDidAppear (bool)
    {
        if (processorHolder.get() != nullptr)
            if (AudioProcessorEditor* editor = getAudioProcessor().getActiveEditor())
                editor->setVisible (true);
    }

    void viewDidDisappear (bool)
    {
        if (processorHolder.get() != nullptr)
            if (AudioProcessorEditor* editor = getAudioProcessor().getActiveEditor())
                editor->setVisible (false);
    }

    CGSize getPreferredContentSize() const
    {
        return CGSizeMake (static_cast<float> (preferredSize.getWidth()),
                           static_cast<float> (preferredSize.getHeight()));
    }

    //==============================================================================
    AUAudioUnit* createAudioUnit (const AudioComponentDescription& descr, NSError** error)
    {
        const auto holder = [&]
        {
            if (auto initialisedHolder = processorHolder.get())
                return initialisedHolder;

            waitForExecutionOnMainThread ([this] { [myself view]; });
            return processorHolder.get();
        }();

        if (holder == nullptr)
            return nullptr;

        return [(new JuceAudioUnitv3 (holder, descr, 0, error))->getAudioUnit() autorelease];
    }

private:
    template <typename Callback>
    static void waitForExecutionOnMainThread (Callback&& callback)
    {
        if (MessageManager::getInstance()->isThisTheMessageThread())
        {
            callback();
            return;
        }

        std::promise<void> promise;

        MessageManager::callAsync ([&]
        {
            callback();
            promise.set_value();
        });

        promise.get_future().get();
    }

    // There's a chance that createAudioUnit will be called from a background
    // thread while the processorHolder is being updated on the main thread.
    class LockedProcessorHolder
    {
    public:
        AudioProcessorHolder::Ptr get() const
        {
            const ScopedLock lock (mutex);
            return holder;
        }

        LockedProcessorHolder& operator= (const AudioProcessorHolder::Ptr& other)
        {
            const ScopedLock lock (mutex);
            holder = other;
            return *this;
        }

    private:
        mutable CriticalSection mutex;
        AudioProcessorHolder::Ptr holder;
    };

    //==============================================================================
    AUViewController<AUAudioUnitFactory>* myself;
    LockedProcessorHolder processorHolder;
    Rectangle<int> preferredSize { 1, 1 };

    //==============================================================================
    AudioProcessor& getAudioProcessor() const noexcept       { return **processorHolder.get(); }
};

//==============================================================================
// necessary glue code
@interface JUCE_VIEWCONTROLLER_OBJC_NAME (JucePlugin_AUExportPrefix) : AUViewController<AUAudioUnitFactory>
@end

@implementation JUCE_VIEWCONTROLLER_OBJC_NAME (JucePlugin_AUExportPrefix)
{
    std::unique_ptr<JuceAUViewController> cpp;
}

- (instancetype) initWithNibName: (nullable NSString*) nib bundle: (nullable NSBundle*) bndl { self = [super initWithNibName: nib bundle: bndl]; cpp.reset (new JuceAUViewController (self)); return self; }
- (void) loadView                { cpp->loadView(); }
- (AUAudioUnit *) createAudioUnitWithComponentDescription: (AudioComponentDescription) desc error: (NSError **) error { return cpp->createAudioUnit (desc, error); }
- (CGSize) preferredContentSize  { return cpp->getPreferredContentSize(); }

// NSViewController and UIViewController have slightly different names for this function
- (void) viewDidLayoutSubviews   { cpp->viewDidLayoutSubviews(); }
- (void) viewDidLayout           { cpp->viewDidLayoutSubviews(); }

- (void) didReceiveMemoryWarning { cpp->didReceiveMemoryWarning(); }
#if JUCE_IOS
- (void) viewDidAppear: (BOOL) animated { cpp->viewDidAppear (animated); [super viewDidAppear:animated]; }
- (void) viewDidDisappear: (BOOL) animated { cpp->viewDidDisappear (animated); [super viewDidDisappear:animated]; }
#endif
@end

//==============================================================================
#if JUCE_IOS
JUCE_BEGIN_IGNORE_WARNINGS_GCC_LIKE ("-Wmissing-prototypes")

bool JUCE_CALLTYPE juce_isInterAppAudioConnected() { return false; }
void JUCE_CALLTYPE juce_switchToHostApplication()  {}
Image JUCE_CALLTYPE juce_getIAAHostIcon (int)      { return {}; }

JUCE_END_IGNORE_WARNINGS_GCC_LIKE
#endif

JUCE_END_IGNORE_WARNINGS_GCC_LIKE
#endif
