
#include "FaustAU_CustomView.h"
#include "FaustAU.h"

static const CGFloat kMinimumViewportWidth = 360.0;
static const CGFloat kMinimumViewportHeight = 260.0;
static const CGFloat kDefaultViewportWidth = 600.0;
static const CGFloat kDefaultViewportHeight = 380.0;
static const CGFloat kControlStripHeight = 34.0;
static const CGFloat kGroupPadding = 10.0;
static const CGFloat kGroupSpacing = 10.0;
static const CGFloat kLabelColumnWidth = 88.0;
static const CGFloat kValueColumnWidth = 68.0;
static const CGFloat kSliderWidth = 170.0;
static const CGFloat kKnobDiameter = 42.0;
static const CGFloat kKnobCellWidth = 92.0;
static const CGFloat kKnobCellHeight = 82.0;

static double AbsoluteDistance(double lhs, double rhs)
{
    double distance = lhs - rhs;
    return (distance < 0.0) ? -distance : distance;
}

static NSInteger ClosestValueIndex(const std::vector<double>& values, double value)
{
    if (values.empty()) {
        return -1;
    }

    NSInteger bestIndex = 0;
    double bestDistance = AbsoluteDistance(values[0], value);
    for (size_t i = 1; i < values.size(); i++) {
        double distance = AbsoluteDistance(values[i], value);
        if (distance < bestDistance) {
            bestDistance = distance;
            bestIndex = i;
        }
    }
    return bestIndex;
}

static CGFloat WidthForTitle(NSString* title, CGFloat minimumWidth)
{
    if (!title) {
        return minimumWidth;
    }

    NSDictionary* attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:[NSFont systemFontSize]]
    };
    CGFloat measuredWidth = ceil([title sizeWithAttributes:attributes].width) + 18.0;
    return MAX(minimumWidth, measuredWidth);
}

static CGFloat ClampedLabelWidth(const char* label)
{
    if (!label || label[0] == '\0') {
        return 0.0;
    }
    NSString* title = [NSString stringWithCString:label encoding:NSUTF8StringEncoding];
    return MIN(WidthForTitle(title, 56.0), 120.0);
}

@implementation FaustAU_CustomView

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        preferredViewSize = frame.size;
        scrollView = nil;
        mAU = NULL;
        timer = nil;
        monitor = false;
        usesBargraphs = false;
        uiBuilt = false;
        buildRetryScheduled = false;
        parameterListenersAdded = false;
        mAUEventListener = NULL;
        for (int i = 0; i < MAX_CONTROLS; i++) {
            paramValues[i] = nil;
        }
        [self setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    }
    return self;
}

- (void)setPreferredSize:(NSSize)inPreferredSize
{
    preferredViewSize = inPreferredSize;
}

- (void)scheduleBuildRetry
{
    if (!mAU || uiBuilt || buildRetryScheduled) {
        return;
    }

    buildRetryScheduled = true;
    [self performSelector:@selector(buildUIIfReady) withObject:nil afterDelay:0.1];
}

- (NSString*)displayStringForObject:(auUIObject*)object value:(Float32)value
{
    if (object && object->fZone) {
        auUI* dspUI = [self dspUI];
        if (dspUI) {
            std::string unit = dspUI->getUnit(object->fZone);
            if (!unit.empty()) {
                return [NSString stringWithFormat:@"%9.2f %s", value, unit.c_str()];
            }
        }
    }
    return [NSString stringWithFormat:@"%9.2f", value];
}

- (void)applyMetadataToView:(NSView*)view labelView:(NSView*)labelView object:(auUIObject*)object ui:(auUI*)dspUI
{
    if (!view || !object || !object->fZone || !dspUI) {
        return;
    }

    std::string tooltip = dspUI->getTooltip(object->fZone);
    if (!tooltip.empty()) {
        NSString* tip = [NSString stringWithCString:tooltip.c_str() encoding:NSUTF8StringEncoding];
        [view setToolTip:tip];
        [labelView setToolTip:tip];
    }
}

- (int)controlIDForObject:(auUIObject*)object ui:(auUI*)dspUI
{
    for (int i = 0; i < dspUI->fUITable.size(); i++) {
        if (dspUI->fUITable[i] == object) {
            return i;
        }
    }
    return -1;
}

- (NSInteger)closestOptionIndexForValue:(double)value
                                options:(const std::vector<std::pair<std::string, double> >&)options
{
    if (options.empty()) {
        return -1;
    }

    NSInteger bestIndex = 0;
    double bestDistance = AbsoluteDistance(options[0].second, value);
    for (NSInteger i = 1; i < options.size(); i++) {
        double distance = AbsoluteDistance(options[i].second, value);
        if (distance < bestDistance) {
            bestDistance = distance;
            bestIndex = i;
        }
    }
    return bestIndex;
}

- (void)applyParameterValue:(Float32)value sender:(id)sender parameterID:(AudioUnitParameterID)paramId
{
    AudioUnitSetParameter(mAU,
                          paramId,
                          kAudioUnitScope_Global,
                          (AudioUnitElement)0,
                          value,
                          0);

    auUI* dspUI = [self dspUI];
    if (dspUI && paramId < dspUI->fUITable.size() && paramValues[paramId]) {
        [paramValues[paramId] setStringValue:[self displayStringForObject:dspUI->fUITable[paramId] value:value]];
    }

    AudioUnitParameter parameter = {mAU, paramId, kAudioUnitScope_Global, 0};
    NSAssert(AUParameterSet(mAUEventListener, sender, &parameter, value, 0) == noErr,
             @"[FaustAU_CustomView applyParameterValue] AUParameterSet()");
}

- (void)syncView:(NSView*)subView object:(auUIObject*)object parameterID:(int)paramId value:(Float32)value
{
    auUI* dspUI = [self dspUI];
    if (!subView || !object || !dspUI) {
        return;
    }

    if ([subView isKindOfClass:[NSPopUpButton class]]) {
        std::vector<std::pair<std::string, double> > options = dspUI->getMenuDescription(object->fZone);
        NSInteger index = [self closestOptionIndexForValue:value options:options];
        if (index >= 0) {
            [(NSPopUpButton*)subView selectItemAtIndex:index];
        }
    } else if ([subView isKindOfClass:[NSSegmentedControl class]]) {
        std::vector<std::pair<std::string, double> > options = dspUI->getRadioDescription(object->fZone);
        NSInteger index = [self closestOptionIndexForValue:value options:options];
        if (index >= 0) {
            [(NSSegmentedControl*)subView setSelectedSegment:index];
        }
    } else if ([subView isKindOfClass:[NSTextField class]] && dynamic_cast<auBargraph*>(object)) {
        [(NSTextField*)subView setStringValue:[self displayStringForObject:object value:value]];
    } else if ([subView isKindOfClass:[NSButton class]] && dynamic_cast<auCheckButton*>(object)) {
        [(NSButton*)subView setState:(value > 0.5f) ? NSOnState : NSOffState];
    } else if ([subView respondsToSelector:@selector(setDoubleValue:)]) {
        [(id)subView setDoubleValue:value];
    }

    if (paramId >= 0 && paramId < MAX_CONTROLS && paramValues[paramId]) {
        [paramValues[paramId] setStringValue:[self displayStringForObject:object value:value]];
    }
}

// This listener responds to parameter changes, gestures, and property notifications
void eventListenerDispatcher (void *inRefCon, void *inObject, const AudioUnitEvent *inEvent, UInt64 inHostTime, Float32 inValue)
{
	FaustAU_CustomView *SELF = (FaustAU_CustomView *)inRefCon;
	[SELF eventListener:inObject event: inEvent value: inValue];
}

void addParamListener (AUEventListenerRef listener, void* refCon, AudioUnitEvent *inEvent)
{
	inEvent->mEventType = kAudioUnitEvent_BeginParameterChangeGesture;
	verify_noerr ( AUEventListenerAddEventType(	listener, refCon, inEvent));
	
	inEvent->mEventType = kAudioUnitEvent_EndParameterChangeGesture;
	verify_noerr ( AUEventListenerAddEventType(	listener, refCon, inEvent));
	
	inEvent->mEventType = kAudioUnitEvent_ParameterValueChange;
	verify_noerr ( AUEventListenerAddEventType(	listener, refCon, inEvent));
}

- (void)addParameterListenersForUI:(auUI*)dspUI
{
    if (parameterListenersAdded || !dspUI) {
        return;
    }

    AudioUnitEvent auEvent;
    for (int i = 0; i < dspUI->fUITable.size(); i++) {
        if (dspUI->fUITable[i] && dspUI->fUITable[i]->fZone)
        {
            if (dynamic_cast<auButton*>(dspUI->fUITable[i])) {
            }
            else if (dynamic_cast<auToggleButton*>(dspUI->fUITable[i])) {
            }
            else if (dynamic_cast<auCheckButton*>(dspUI->fUITable[i])) {
            }
            else {
                AudioUnitParameter parameter =
                {
                    mAU,
                    (AudioUnitParameterID)i,
                    kAudioUnitScope_Global,
                    0
                };
                auEvent.mArgument.mParameter = parameter;
                addParamListener(mAUEventListener, self, &auEvent);
            }
        }
    }

    parameterListenersAdded = true;
}

- (void)addListeners
{
    if (mAU) {
		verify_noerr( AUEventListenerCreate(eventListenerDispatcher, self,
											CFRunLoopGetCurrent(), kCFRunLoopDefaultMode, 0.05, 0.05,
											&mAUEventListener));

        AudioUnitEvent auEvent;
        auEvent.mEventType = kAudioUnitEvent_PropertyChange;
        auEvent.mArgument.mProperty.mAudioUnit = mAU;
        auEvent.mArgument.mProperty.mPropertyID = kAudioUnitCustomProperty_dspUI;
        auEvent.mArgument.mProperty.mScope = kAudioUnitScope_Global;
        auEvent.mArgument.mProperty.mElement = 0;
        verify_noerr(AUEventListenerAddEventType(mAUEventListener, self, &auEvent));

        [self addParameterListenersForUI:[self dspUI]];
	}
	
}

- (void)removeListeners
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(buildUIIfReady) object:nil];
	if (mAUEventListener) verify_noerr (AUListenerDispose(mAUEventListener));
	mAUEventListener = NULL;
    buildRetryScheduled = false;
    parameterListenersAdded = false;
	mAU = NULL;
}

- (auUI*) dspUI
{
    auUI* dspUI = NULL;
    UInt32 dataSize = sizeof(auUI*);
    ComponentResult result = AudioUnitGetProperty(mAU,
                                                  (AudioUnitPropertyID)kAudioUnitCustomProperty_dspUI,
                                                  kAudioUnitScope_Global,
                                                  (AudioUnitElement)0, //inElement
                                                  (void*)&dspUI,
                                                  &dataSize);
    if (result != noErr || dataSize != sizeof(auUI*)) {
        return NULL;
    }
    return dspUI;
}

/*
 - (BOOL)isFlipped {
     return YES;
 }
*/

- (void)dealloc
{
     [self unsetTimer];
     [self removeListeners];
     [[NSNotificationCenter defaultCenter] removeObserver: self];
     [super dealloc];
}

- (NSButton*)addButton:(NSBox*) nsBox :(auButton*)fButton :(int)controlId :(NSPoint&) origin :(NSSize&) size :(bool)isVerticalBox
{
    int width = WidthForTitle([NSString stringWithCString:fButton->fLabel.c_str() encoding:NSUTF8StringEncoding], 72.0);
    int height = 26;
    NSRect buttonFrame = NSMakeRect(origin.x, origin.y, width, height);

    NSButton* button = [[NSButton alloc] initWithFrame:buttonFrame];
    [button setTitle:[[NSString alloc] initWithCString:fButton->fLabel.c_str() encoding:NSUTF8StringEncoding]];
    [button setButtonType:NSMomentaryPushInButton];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setBordered:YES];
    [button setIdentifier:[NSString stringWithFormat:@"%d", controlId]];
    [button setTarget:self];
    [button setAction:@selector(buttonEventChanged:)];
    [[button cell] sendActionOn:(NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp)];
    
    [nsBox addSubview:button];
    [self applyMetadataToView:button labelView:nil object:fButton ui:[self dspUI]];
    
    if (isVerticalBox)
    {
        origin.y += height;
        size.height += height;
        if (size.width < width)
            size.width = width;
    }
    else
    {
        origin.x += width;
        size.width += width;
        if (size.height < height)
            size.height = height;
    }
    
    return button;
}

- (NSButton*)addCheckButton:(NSBox*) nsBox :(auCheckButton*)fButton :(int)controlId :(NSPoint&) origin :(NSSize&) size :(bool)isVerticalBox
{
    int width = WidthForTitle([NSString stringWithCString:fButton->fLabel.c_str() encoding:NSUTF8StringEncoding], 84.0);
    int height = 26;
    
    NSRect frame = NSMakeRect(origin.x, origin.y, width, height);
    
    NSButton* button = [[NSButton alloc] initWithFrame:frame ];
    
    [button setTitle:[[NSString alloc] initWithCString:fButton->fLabel.c_str() encoding:NSUTF8StringEncoding]];
    
    [button setButtonType:NSSwitchButton];
    [button setBezelStyle:NSRoundedBezelStyle];
    
    NSString *identifier = [NSString stringWithFormat:@"%d",controlId];
    [button setIdentifier: identifier];
    
    [button setTarget:self];
    [button setAction:@selector(paramChanged:)];
    
    [nsBox addSubview:button];
    [self applyMetadataToView:button labelView:nil object:fButton ui:[self dspUI]];
    
    if (isVerticalBox)
    {
        origin.y += height;
        size.height += height;
        if (size.width < width)
            size.width = width;
    }
    else
    {
        origin.x += width;
        size.width += width;
        if (size.height < height)
            size.height = height;
    }
    
    return button;
}

- (NSTextField*)addTextField:(NSBox*) nsBox :(const char*)label :(int)controlId :(NSPoint&) origin :(bool)isVerticalBox
{
    int width = 100;
    int height = 18;
    
    NSTextField* textField;
    
    textField = [[NSTextField alloc] initWithFrame:NSMakeRect(origin.x, origin.y, width, height)];
    
    [textField setBezeled:NO];
    [textField setDrawsBackground:NO];
    [textField setEditable:NO];
    [textField setSelectable:NO];
    [textField setIdentifier: @"200"]; //TODO
    [textField setStringValue:[[NSString alloc] initWithCString:label encoding:NSUTF8StringEncoding]];
    [textField setTextColor:[NSColor labelColor]];
    [textField setFont:[NSFont systemFontOfSize:12.0]];
    
    [nsBox addSubview:textField];
    
    return textField;
}

- (double)valueForEnumSender:(id)sender parameterID:(AudioUnitParameterID)paramId
{
    if ([sender isKindOfClass:[NSPopUpButton class]]) {
        NSMenuItem* item = [(NSPopUpButton*)sender selectedItem];
        id representedObject = [item representedObject];
        return representedObject ? [representedObject doubleValue] : 0.0;
    }

    if ([sender isKindOfClass:[NSSegmentedControl class]]) {
        NSInteger selectedSegment = [(NSSegmentedControl*)sender selectedSegment];
        std::map<int, std::vector<double> >::iterator values = enumValueMap.find(paramId);
        if (values != enumValueMap.end() && selectedSegment >= 0 &&
            selectedSegment < values->second.size()) {
            return values->second[selectedSegment];
        }
    }

    return [sender doubleValue];
}

- (void)syncEnumView:(NSView*)view parameterID:(AudioUnitParameterID)paramId value:(Float32)value
{
    std::map<int, std::vector<double> >::iterator values = enumValueMap.find(paramId);
    if (values == enumValueMap.end()) {
        return;
    }

    NSInteger selectedIndex = ClosestValueIndex(values->second, value);
    if (selectedIndex < 0) {
        return;
    }

    if ([view isKindOfClass:[NSPopUpButton class]]) {
        [(NSPopUpButton*)view selectItemAtIndex:selectedIndex];
    } else if ([view isKindOfClass:[NSSegmentedControl class]]) {
        [(NSSegmentedControl*)view setSelectedSegment:selectedIndex];
    }
}

- (NSView*)addMenu:(NSBox*)nsBox :(auSlider*)fSlider :(int)controlId :(NSPoint&)origin :(NSSize&)size :(bool)isVerticalBox
{
    auUI* dspUI = [self dspUI];
    std::vector<std::pair<std::string, double> > options = dspUI ? dspUI->getMenuDescription(fSlider->fZone) : std::vector<std::pair<std::string, double> >();
    if (options.empty()) {
        return [self addSlider:nsBox :fSlider :controlId :origin :size :isVerticalBox];
    }

    NSTextField* labelTextField = NULL;
    CGFloat labelWidth = 0;
    if (strcmp(fSlider->fLabel.c_str(), "")) {
        labelTextField = [self addTextField:nsBox :fSlider->fLabel.c_str() :200 :origin :isVerticalBox];
        [labelTextField setAlignment:NSRightTextAlignment];
        labelWidth = ClampedLabelWidth(fSlider->fLabel.c_str());
        [labelTextField setFrame:NSMakeRect(origin.x, origin.y + 5, labelWidth, 18)];
    }

    Float32 value;
    AudioUnitGetParameter(mAU, controlId, kAudioUnitScope_Global, 0, &value);

    CGFloat popupWidth = 180.0;
    NSInteger selectedIndex = 0;
    enumValueMap[controlId].clear();

    NSPopUpButton* popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(origin.x + labelWidth, origin.y + 3, popupWidth, 26) pullsDown:NO];
    [popup removeAllItems];
    for (size_t i = 0; i < options.size(); i++) {
        NSString* title = [NSString stringWithCString:options[i].first.c_str() encoding:NSUTF8StringEncoding];
        [popup addItemWithTitle:title];
        [[[popup itemArray] lastObject] setRepresentedObject:[NSNumber numberWithDouble:options[i].second]];
        enumValueMap[controlId].push_back(options[i].second);
        popupWidth = MAX(popupWidth, WidthForTitle(title, 180.0));
    }

    selectedIndex = ClosestValueIndex(enumValueMap[controlId], value);
    [popup setFrame:NSMakeRect(origin.x + labelWidth, origin.y + 3, popupWidth, 26)];
    [popup setIdentifier:[NSString stringWithFormat:@"%d", controlId]];
    [popup setTarget:self];
    [popup setAction:@selector(enumControlChanged:)];
    if (selectedIndex >= 0) {
        [popup selectItemAtIndex:selectedIndex];
    }

    [nsBox addSubview:popup];
    [self applyMetadataToView:popup labelView:labelTextField object:fSlider ui:dspUI];

    int totalWidth = popupWidth + labelWidth + 8;
    int totalHeight = 30;
    if (isVerticalBox) {
        origin.y += totalHeight;
        size.height += totalHeight;
        if (size.width < totalWidth) {
            size.width = totalWidth;
        }
    } else {
        origin.x += totalWidth;
        size.width += totalWidth;
        if (size.height < totalHeight) {
            size.height = totalHeight;
        }
    }

    return popup;
}

- (NSView*)addRadio:(NSBox*)nsBox :(auSlider*)fSlider :(int)controlId :(NSPoint&)origin :(NSSize&)size :(bool)isVerticalBox
{
    auUI* dspUI = [self dspUI];
    std::vector<std::pair<std::string, double> > options = dspUI ? dspUI->getRadioDescription(fSlider->fZone) : std::vector<std::pair<std::string, double> >();
    if (options.empty()) {
        return [self addSlider:nsBox :fSlider :controlId :origin :size :isVerticalBox];
    }

    NSTextField* labelTextField = NULL;
    CGFloat labelWidth = 0;
    if (strcmp(fSlider->fLabel.c_str(), "")) {
        labelTextField = [self addTextField:nsBox :fSlider->fLabel.c_str() :200 :origin :isVerticalBox];
        [labelTextField setAlignment:NSRightTextAlignment];
        labelWidth = ClampedLabelWidth(fSlider->fLabel.c_str());
        [labelTextField setFrame:NSMakeRect(origin.x, origin.y + 5, labelWidth, 18)];
    }

    Float32 value;
    AudioUnitGetParameter(mAU, controlId, kAudioUnitScope_Global, 0, &value);

    NSSegmentedControl* radio = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    [radio setSegmentCount:options.size()];
    [radio setTrackingMode:NSSegmentSwitchTrackingSelectOne];
    [radio setIdentifier:[NSString stringWithFormat:@"%d", controlId]];
    [radio setTarget:self];
    [radio setAction:@selector(enumControlChanged:)];

    enumValueMap[controlId].clear();
    CGFloat totalWidth = 0.0;
    for (size_t i = 0; i < options.size(); i++) {
        NSString* title = [NSString stringWithCString:options[i].first.c_str() encoding:NSUTF8StringEncoding];
        CGFloat segmentWidth = WidthForTitle(title, 54.0);
        [radio setLabel:title forSegment:i];
        [radio setWidth:segmentWidth forSegment:i];
        totalWidth += segmentWidth;
        enumValueMap[controlId].push_back(options[i].second);
    }

    NSInteger selectedIndex = ClosestValueIndex(enumValueMap[controlId], value);
    if (selectedIndex >= 0) {
        [radio setSelectedSegment:selectedIndex];
    }

    [radio setFrame:NSMakeRect(origin.x + labelWidth, origin.y + 2, totalWidth, 28)];
    [nsBox addSubview:radio];
    [self applyMetadataToView:radio labelView:labelTextField object:fSlider ui:dspUI];

    int totalControlWidth = labelWidth + totalWidth;
    int totalHeight = 30;
    if (isVerticalBox) {
        origin.y += totalHeight;
        size.height += totalHeight;
        if (size.width < totalControlWidth) {
            size.width = totalControlWidth;
        }
    } else {
        origin.x += totalControlWidth;
        size.width += totalControlWidth;
        if (size.height < totalHeight) {
            size.height = totalHeight;
        }
    }

    return radio;
}

- (NSView*)addNumericalBargraph:(NSBox*)nsBox :(auBargraph*)fBargraph :(int)controlId :(NSPoint&)origin :(NSSize&)size :(bool)isVerticalBox
{
    NSTextField* labelTextField = NULL;
    CGFloat labelWidth = 0;
    if (strcmp(fBargraph->fLabel.c_str(), "")) {
        labelTextField = [self addTextField:nsBox :fBargraph->fLabel.c_str() :200 :origin :isVerticalBox];
        [labelTextField setAlignment:NSRightTextAlignment];
        labelWidth = ClampedLabelWidth(fBargraph->fLabel.c_str());
        [labelTextField setFrame:NSMakeRect(origin.x, origin.y + 4, labelWidth, 18)];
    }

    Float32 value;
    AudioUnitGetParameter(mAU, controlId, kAudioUnitScope_Global, 0, &value);

    NSTextField* valueField = [[NSTextField alloc] initWithFrame:NSMakeRect(origin.x + labelWidth + 6, origin.y + 2, 120, 22)];
    [valueField setBezeled:YES];
    [valueField setEditable:NO];
    [valueField setSelectable:NO];
    [valueField setAlignment:NSRightTextAlignment];
    [valueField setIdentifier:[NSString stringWithFormat:@"%d", controlId]];
    [valueField setStringValue:[self displayStringForObject:fBargraph value:value]];
    [nsBox addSubview:valueField];
    [self applyMetadataToView:valueField labelView:labelTextField object:fBargraph ui:[self dspUI]];

    if (isVerticalBox) {
        origin.y += 28;
        size.height += 28;
        if (size.width < labelWidth + 126) {
            size.width = labelWidth + 126;
        }
    } else {
        origin.x += labelWidth + 126;
        size.width += labelWidth + 126;
        if (size.height < 28) {
            size.height = 28;
        }
    }

    paramValues[controlId] = valueField;
    return valueField;
}

- (NSView*)addLedBargraph:(NSBox*)nsBox :(auBargraph*)fBargraph :(int)controlId :(NSPoint&)origin :(NSSize&)size :(bool)isVerticalBox
{
    NSTextField* labelTextField = NULL;
    CGFloat labelWidth = 0;
    if (strcmp(fBargraph->fLabel.c_str(), "")) {
        labelTextField = [self addTextField:nsBox :fBargraph->fLabel.c_str() :200 :origin :isVerticalBox];
        [labelTextField setAlignment:NSRightTextAlignment];
        labelWidth = ClampedLabelWidth(fBargraph->fLabel.c_str());
        [labelTextField setFrame:NSMakeRect(origin.x, origin.y + 4, labelWidth, 18)];
    }

    Float32 value;
    AudioUnitGetParameter(mAU, controlId, kAudioUnitScope_Global, 0, &value);

    int width = fBargraph->fIsVertical ? 18 : 90;
    int height = fBargraph->fIsVertical ? 90 : 18;
    NSLevelIndicator* indicator = [[NSLevelIndicator alloc] initWithFrame:NSMakeRect(origin.x + labelWidth, origin.y + 4, width, height)];
    [indicator setLevelIndicatorStyle:NSDiscreteCapacityLevelIndicatorStyle];
    [indicator setMinValue:fBargraph->fMin];
    [indicator setMaxValue:fBargraph->fMax];
    [indicator setWarningValue:fBargraph->fMax];
    [indicator setCriticalValue:fBargraph->fMax];
    [indicator setEditable:NO];
    [indicator setEnabled:NO];
    [indicator setDoubleValue:value];
    [indicator setIdentifier:[NSString stringWithFormat:@"%d", controlId]];
    [nsBox addSubview:indicator];
    [self applyMetadataToView:indicator labelView:labelTextField object:fBargraph ui:[self dspUI]];

    NSPoint org;
    org.x = origin.x + labelWidth + width + 8;
    org.y = origin.y;
    NSTextField* valueTextField = [self addTextField:nsBox :[[self displayStringForObject:fBargraph value:value] UTF8String] :-1 :org :isVerticalBox];
    [valueTextField setAlignment:NSLeftTextAlignment];

    if (isVerticalBox) {
        origin.y += MAX(height, 24);
        size.height += MAX(height, 24);
        if (size.width < width + labelWidth + kValueColumnWidth + 16) {
            size.width = width + labelWidth + kValueColumnWidth + 16;
        }
    } else {
        origin.x += width + labelWidth + kValueColumnWidth + 16;
        size.width += width + labelWidth + kValueColumnWidth + 16;
        if (size.height < height) {
            size.height = height;
        }
    }

    paramValues[controlId] = valueTextField;
    return indicator;
}

- (NSView*)addUIObject:(NSBox*)nsBox :(auUIObject*)object :(int)controlId :(NSPoint&)origin :(NSSize&)size :(bool)isVerticalBox
{
    auUI* dspUI = [self dspUI];

    if (dynamic_cast<auButton*>(object)) {
        return [self addButton:nsBox :(auButton*)object :controlId :origin :size :isVerticalBox];
    }
    else if (dynamic_cast<auCheckButton*>(object)) {
        return [self addCheckButton:nsBox :(auCheckButton*)object :controlId :origin :size :isVerticalBox];
    }
    else if (dynamic_cast<auSlider*>(object)) {
        if (dspUI && dspUI->isMenu(object->fZone)) {
            return [self addMenu:nsBox :(auSlider*)object :controlId :origin :size :isVerticalBox];
        } else if (dspUI && dspUI->isRadio(object->fZone)) {
            return [self addRadio:nsBox :(auSlider*)object :controlId :origin :size :isVerticalBox];
        } else if (dspUI && dspUI->isKnob(object->fZone)) {
            return [self addKnob:nsBox :(auSlider*)object :controlId :origin :size :isVerticalBox];
        } else {
            return [self addSlider:nsBox :(auSlider*)object :controlId :origin :size :isVerticalBox];
        }
    }
    else if (dynamic_cast<auBargraph*>(object)) {
        if (dspUI && dspUI->isNumerical(object->fZone)) {
            return [self addNumericalBargraph:nsBox :(auBargraph*)object :controlId :origin :size :isVerticalBox];
        } else if (dspUI && dspUI->isLed(object->fZone)) {
            return [self addLedBargraph:nsBox :(auBargraph*)object :controlId :origin :size :isVerticalBox];
        } else {
            return [self addBargraph:nsBox :(auBargraph*)object :controlId :origin :size :isVerticalBox];
        }
    }

    return nil;
}

- (FaustAU_Slider*)addSlider:(NSBox*) nsBox :(auSlider*)fSlider :(int)controlId :(NSPoint&) origin :(NSSize&) size :(bool)isVerticalBox
{
    CGFloat labelWidth = 0;
    
    NSTextField* labelTextField = NULL;
    
    if (strcmp(fSlider->fLabel.c_str(), "")) {
        labelTextField = [self addTextField :nsBox :fSlider->fLabel.c_str() :200 :origin :isVerticalBox];
        [labelTextField setAlignment: NSRightTextAlignment];
        labelWidth = ClampedLabelWidth(fSlider->fLabel.c_str());
        [labelTextField setFrame:NSMakeRect(origin.x, origin.y + 5, labelWidth, 18)];
    }
    
    CGFloat width;
    CGFloat height;
    float value;
    
    if (fSlider->fIsVertical) {
        width = 15;
        height = 100;
    } else {
        width = kSliderWidth;
        height = 24;
    }
    
    FaustAU_Slider* slider;
    slider = [[FaustAU_Slider alloc] initWithFrame:NSMakeRect(origin.x + labelWidth + 6, origin.y + 2, width, height)];
    [slider setMinValue:fSlider->fMin];
    [slider setMaxValue:fSlider->fMax];
    
    AudioUnitGetParameter(mAU, controlId, kAudioUnitScope_Global, 0, &value);
    [slider setDoubleValue:value];
    
    //TODO [slider setNumberOfTickMarks: (fSlider->fMax - fSlider->fMin) / fSlider->fStep];
    NSString *identifier = [NSString stringWithFormat:@"%d",controlId];
    [slider setIdentifier: identifier];
    
    [slider setContinuous:YES];
    
    [slider setAction:@selector(paramChanged:)];
    [slider setTarget:self];
    
    [nsBox addSubview:slider];
    
    NSPoint org;
    org.x = origin.x + labelWidth + width + 12;
    org.y = origin.y;
    NSTextField* valueTextField = [self addTextField :nsBox :[[self displayStringForObject:fSlider value:value] UTF8String] :-1 :org :isVerticalBox];
    [valueTextField setAlignment: NSLeftTextAlignment];
    [valueTextField setFrame:NSMakeRect(org.x, origin.y + 5, kValueColumnWidth, 18)];
    
    if (isVerticalBox)
    {
        origin.y += 30;
        size.height += 30;
        if (size.width < width + labelWidth + kValueColumnWidth + 20)
            size.width = width + labelWidth + kValueColumnWidth + 20;
    }
    else
    {
        origin.x += width + labelWidth + kValueColumnWidth + 20;
        size.width += width + labelWidth + kValueColumnWidth + 20;
        if (size.height < 30)
            size.height = 30;
    }
    
    paramValues[controlId] = valueTextField;
    
    if (labelTextField)
        [slider setLabelTextField: labelTextField];
    
    [slider setValueTextField: valueTextField];
    [self applyMetadataToView:slider labelView:labelTextField object:fSlider ui:[self dspUI]];
    return slider;
}

- (NSArray*)generateArrayFrom:(float)start to:(float)stop step:(float)step
{
    NSMutableArray *a = [[NSMutableArray alloc] init];
    float v = start;
    
    while (v <= stop)
    {
        [a addObject:@(v)];
        v += step;
        
    }
    return a;
}

- (FaustAU_Knob*)addKnob:(NSBox*) nsBox :(auSlider*)fSlider :(int)controlId :(NSPoint&) origin :(NSSize&) size :(bool)isVerticalBox
{
    NSTextField* labelTextField = NULL;
    CGFloat cellWidth = kKnobCellWidth;
    
    if (strcmp(fSlider->fLabel.c_str(), "")) {
        cellWidth = MAX(kKnobCellWidth, WidthForTitle([NSString stringWithCString:fSlider->fLabel.c_str() encoding:NSUTF8StringEncoding], kKnobCellWidth));
        NSPoint labelOrigin = origin;
        labelOrigin.y = origin.y + kKnobDiameter + 22;
        labelTextField = [self addTextField :nsBox :fSlider->fLabel.c_str() :200 :labelOrigin :isVerticalBox];
        [labelTextField setAlignment: NSCenterTextAlignment];
        [labelTextField setFrame:NSMakeRect(origin.x, labelOrigin.y, cellWidth, 18)];
    }
    
    CGFloat width = kKnobDiameter;
    CGFloat height = kKnobDiameter;
    float value;
    
    AudioUnitGetParameter(mAU, controlId, kAudioUnitScope_Global, 0, &value);
    int initAngle =  225.0 - 270.0 * (value - fSlider->fMin) / (fSlider->fMax - fSlider->fMin);
    
    CGFloat knobX = origin.x + floor((cellWidth - width) / 2.0);
    CGFloat knobY = origin.y + 18.0;
    FaustAU_Knob *knob = [[FaustAU_Knob alloc] initWithFrame:NSMakeRect(knobX, knobY, width, height)
                                                  withInsets:10
                                    withControlPointDiameter:2
                                       withControlPointColor:[NSColor darkGrayColor]
                                               withKnobColor:[NSColor whiteColor]
                                         withBackgroundColor:[NSColor clearColor]
                                            withCurrentAngle:initAngle];
    
    
    knob->control = controlId;
    knob->controlPoint->delegate = self;
    knob->controlPoint->data = [self generateArrayFrom:fSlider->fMin to:fSlider->fMax step:fSlider->fStep]; //TODO step
    
    NSString *identifier = [NSString stringWithFormat:@"%d",controlId];
    [knob setIdentifier: identifier];
    
    [nsBox addSubview:knob];
    
    NSPoint org;
    org.x = origin.x;
    org.y = origin.y;
    NSTextField* valueTextField = [self addTextField :nsBox :[[self displayStringForObject:fSlider value:value] UTF8String] :-1 :org :isVerticalBox];
    [valueTextField setAlignment: NSCenterTextAlignment];
    [valueTextField setFrame:NSMakeRect(origin.x, origin.y, cellWidth, 18)];
    
    if (isVerticalBox)
    {
        origin.y += kKnobCellHeight;
        size.height += kKnobCellHeight;
        if (size.width < cellWidth)
            size.width = cellWidth;
    }
    else
    {
        origin.x += cellWidth;
        size.width += cellWidth;
        if (size.height < kKnobCellHeight)
            size.height = kKnobCellHeight;
    }
    
    paramValues[controlId] = valueTextField;
    
    if (labelTextField)
        [knob setLabelTextField: labelTextField];
    
    [knob setValueTextField: valueTextField];
    [self applyMetadataToView:knob labelView:labelTextField object:fSlider ui:[self dspUI]];
    return knob;
}

- (FaustAU_Bargraph*)addBargraph:(NSBox*) nsBox :(auBargraph*)fBargraph :(int)controlId :(NSPoint&) origin :(NSSize&) size :(bool)isVerticalBox
{
    NSTextField* labelTextField = NULL;
    CGFloat labelWidth = 0;
    
    if (strcmp(fBargraph->fLabel.c_str(), "")) {
        labelTextField = [self addTextField :nsBox :fBargraph->fLabel.c_str() :200 :origin :isVerticalBox];
        [labelTextField setAlignment: NSRightTextAlignment];
        labelWidth = ClampedLabelWidth(fBargraph->fLabel.c_str());
        [labelTextField setFrame:NSMakeRect(origin.x, origin.y + 6, labelWidth, 18)];
    }
    
    int width;
    int height;
    float value;
    
    if (fBargraph->fIsVertical) {
        width = 35;
        height = 100;
    } else {
        width = kSliderWidth;
        height = 28;
    }
    
    FaustAU_Bargraph* bargraph;
    bargraph = [[FaustAU_Bargraph alloc] initWithFrame:NSMakeRect(origin.x + labelWidth + 6, origin.y + 2, width, height)];
    [bargraph setMinValue:fBargraph->fMin];
    [bargraph setMaxValue:fBargraph->fMax];
    
    AudioUnitGetParameter(mAU, controlId, kAudioUnitScope_Global, 0, &value);
    [bargraph setDoubleValue:value];
    
    //TODO [barGraph setNumberOfTickMarks: (fBargraph->fMax - fBargraph->fMin) / fBargraph->fStep];
    NSString *identifier = [NSString stringWithFormat:@"%d",controlId];
    [bargraph setIdentifier: identifier];
    
    [bargraph setContinuous:YES];
    
    [bargraph setAction:@selector(paramChanged:)];
    [bargraph setTarget:self];
    
    [nsBox addSubview:bargraph];
    
    NSPoint org;
    org.x = origin.x + labelWidth + width + 12;
    org.y = origin.y;
    NSTextField* valueTextField = [self addTextField :nsBox :[[self displayStringForObject:fBargraph value:value] UTF8String] :-1 :org :isVerticalBox];
    [valueTextField setAlignment: NSLeftTextAlignment];
    [valueTextField setFrame:NSMakeRect(org.x, origin.y + 6, kValueColumnWidth, 18)];
    
    if (isVerticalBox)
    {
        origin.y += 32;
        size.height += 32;
        if (size.width < width + labelWidth + kValueColumnWidth + 20)
            size.width = width + labelWidth + kValueColumnWidth + 20;
    }
    else
    {
        origin.x += width + labelWidth + kValueColumnWidth + 20;
        size.width += width + labelWidth + kValueColumnWidth + 20;
        if (size.height < 32)
            size.height = 32;
    }
    
    paramValues[controlId] = valueTextField;
    
    if (labelTextField)
        [bargraph setLabelTextField: labelTextField];
    
    [bargraph setValueTextField: valueTextField];
    [self applyMetadataToView:bargraph labelView:labelTextField object:fBargraph ui:[self dspUI]];
    
    return bargraph;
}

- (NSBox*)addBox:(NSBox*) nsParentBox :(auBox*)fThisBox :(NSPoint&) parentBoxOrigin :(NSSize&) parentBoxSize :(bool)isParentVerticalBox {
    
    auUIObject* childUIObject;
    
    NSBox* nsThisBox = [[NSBox alloc] init];
    NSPoint thisBoxOrigin;
    NSSize thisBoxSize;
    
    thisBoxOrigin.x = kGroupPadding;
    thisBoxOrigin.y = kGroupPadding;
    thisBoxSize.width = thisBoxSize.height = 0;
    
    [nsThisBox setTitle:[[NSString alloc] initWithCString:fThisBox->fLabel.c_str() encoding:NSUTF8StringEncoding]];
    [nsThisBox setBoxType:NSBoxPrimary];
    [nsThisBox setBorderType:NSGrooveBorder];
    [nsThisBox setTransparent:NO];
    
    auUI* dspUI = [self dspUI];
    
    if (fThisBox->fIsTabBox) {
        NSTabView* tabView = [[NSTabView alloc] initWithFrame:NSZeroRect];
        CGFloat maxTabWidth = 160;
        CGFloat maxTabHeight = 120;

        for (int i = 0; i < fThisBox->fChildren.size(); i++) {
            childUIObject = fThisBox->fChildren[i];

            if (childUIObject->fZone && dspUI->isHidden(childUIObject->fZone)) {
                continue;
            }

            NSTabViewItem* tabItem = [[NSTabViewItem alloc] initWithIdentifier:nil];
            NSString* tabLabel = [NSString stringWithCString:childUIObject->fLabel.c_str() encoding:NSUTF8StringEncoding];
            if ([tabLabel length] == 0) {
                tabLabel = [NSString stringWithFormat:@"Tab %d", i + 1];
            }
            [tabItem setLabel:tabLabel];

            NSBox* tabPage = [[NSBox alloc] init];
            [tabPage setTitle:@""];

            NSPoint tabOrigin = NSMakePoint(0, 0);
            NSSize tabSize = NSMakeSize(0, 0);

            if (dynamic_cast<auBox*>(childUIObject)) {
                NSBox* childBox = [self addBox:tabPage :(auBox*)childUIObject :tabOrigin :tabSize :true];
                [childBox setTitle:@""];
            } else {
                int controlId = [self controlIDForObject:childUIObject ui:dspUI];
                NSView* childView = [self addUIObject:tabPage :childUIObject :controlId :tabOrigin :tabSize :true];
                if (childView && controlId >= 0) {
                    viewMap[controlId] = childView;
                }
            }

            NSRect tabFrame = NSMakeRect(0, 0, MAX(tabSize.width + 25, 180), MAX(tabSize.height + 25, 140));
            [tabPage setFrame:tabFrame];
            [tabItem setView:tabPage];
            [tabView addTabViewItem:tabItem];

            maxTabWidth = MAX(maxTabWidth, tabFrame.size.width);
            maxTabHeight = MAX(maxTabHeight, tabFrame.size.height);

            [tabItem release];
            [tabPage release];
        }

            [tabView setFrame:NSMakeRect(kGroupPadding, kGroupPadding, maxTabWidth + 8, maxTabHeight + 28)];
        [nsThisBox addSubview:tabView];
        [tabView release];

        thisBoxSize.width = maxTabWidth + 2 * kGroupPadding + 8;
        thisBoxSize.height = maxTabHeight + 2 * kGroupPadding + 28;
    } else {
        for (int i = 0; i < fThisBox->fChildren.size(); i++) {
            if (fThisBox->fIsVertical) {
                childUIObject = fThisBox->fChildren[fThisBox->fChildren.size() - i - 1]; // not isFlipped
            } else {
                childUIObject = fThisBox->fChildren[i];
            }

            if (childUIObject->fZone && dspUI->isHidden(childUIObject->fZone)) {
                continue;
            }

            if (dynamic_cast<auBox*>(childUIObject)) {
                [self addBox:nsThisBox :(auBox*)childUIObject :thisBoxOrigin :thisBoxSize :fThisBox->fIsVertical];
            } else {
                int controlId = [self controlIDForObject:childUIObject ui:dspUI];
                NSView* childView = [self addUIObject:nsThisBox :childUIObject :controlId :thisBoxOrigin :thisBoxSize :fThisBox->fIsVertical];
                if (childView && controlId >= 0) {
                    viewMap[controlId] = childView;
                }
            }
        }
    }
    
    
    NSRect frame;
    frame.origin.x = parentBoxOrigin.x;
    frame.origin.y = parentBoxOrigin.y;
    CGFloat titleInset = (strcmp(fThisBox->fLabel.c_str(), "") == 0) ? 0.0 : 18.0;
    frame.size.width  = thisBoxSize.width + (2 * kGroupPadding);
    frame.size.height = thisBoxSize.height + (2 * kGroupPadding) + titleInset;
    [nsThisBox setFrame:frame];
    
    [nsThisBox setNeedsDisplay:YES];
    
    [nsParentBox addSubview:nsThisBox];
    
    if (isParentVerticalBox)
    {
        parentBoxOrigin.x = kGroupPadding;
        parentBoxOrigin.y += thisBoxSize.height + kGroupSpacing + titleInset;
        
        parentBoxSize.height += thisBoxSize.height + kGroupSpacing + titleInset;
        if (parentBoxSize.width < frame.size.width)
            parentBoxSize.width = frame.size.width;
    }
    else
    {
        parentBoxOrigin.x += frame.size.width + kGroupSpacing;
        parentBoxSize.width += frame.size.width + kGroupSpacing;

        if (parentBoxSize.height < frame.size.height)
            parentBoxSize.height = frame.size.height;
        parentBoxOrigin.y = kGroupPadding;
    }
    
    return nsThisBox;
}

-(void)repaint
{
    auUI* dspUI = [self dspUI];
    if (!dspUI || !dspUI->boundingBox) {
        return;
    }

    scrollView = nil;
    NSArray* subviews = [[self subviews] copy];
    for (NSView* subview in subviews) {
        [subview removeFromSuperview];
    }
    [subviews release];

    NSRect frame;
    
    NSPoint origin;
    origin.x = origin.y = 0;
    
    NSSize size;
    size.width = size.height = 0;
    
    NSBox* nsCustomViewBox = [[NSBox alloc] init];
    [nsCustomViewBox setTitle:@""];
    [nsCustomViewBox setBoxType:NSBoxCustom];
    [nsCustomViewBox setBorderType:NSNoBorder];
    [nsCustomViewBox setTransparent:YES];
    [self addBox :nsCustomViewBox :dspUI->boundingBox :origin :size :true];
    
    frame.origin.x  = 0;
    frame.origin.y = kControlStripHeight;
    frame.size.width  = size.width + (2 * kGroupPadding);
    frame.size.height = size.height + (2 * kGroupPadding);
    [nsCustomViewBox setFrame:frame];
    [nsCustomViewBox setNeedsDisplay:YES];
    
    CGFloat contentWidth = MAX(frame.size.width, 220.0);
    CGFloat contentHeight = MAX(frame.size.height + kControlStripHeight, 140.0);
    NSView* documentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, contentWidth, contentHeight)];
    [documentView setWantsLayer:YES];
    documentView.layer.backgroundColor = [[NSColor windowBackgroundColor] CGColor];
    [documentView addSubview:nsCustomViewBox];
    
    //xml button
    NSButton* button;
    NSRect monitorFrame = NSMakeRect(MAX(contentWidth - 70, 10), 6, 55, 24);
    button = [[NSButton alloc] initWithFrame:monitorFrame ];
    [button setTitle:@"XML"];
    [button setButtonType:NSMomentaryPushInButton];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setTarget:self];
    [button setAction:@selector(xmlButtonPushed:)];
    [button setState:TRUE];
    [documentView addSubview:button];
    [button release];
    
    if (usesBargraphs)
    {
        NSRect monitorFrame = NSMakeRect(10, 8, 60, 18);
        button = [[NSButton alloc] initWithFrame:monitorFrame ];
        [button setTitle:@"MON"];
        [button setButtonType:NSSwitchButton];
        [button setBezelStyle:NSRoundedBezelStyle];
        [button setTarget:self];
        [button setAction:@selector(monitorButtonPushed:)];
        [button setState:TRUE];
        [documentView addSubview:button];
        [button release];
    }
    
    NSRect visibleFrame = [[NSScreen mainScreen] visibleFrame];
    CGFloat maxWidth = MAX(kMinimumViewportWidth, floor(visibleFrame.size.width * 0.7));
    CGFloat maxHeight = MAX(kMinimumViewportHeight, floor(visibleFrame.size.height * 0.7));
    CGFloat requestedWidth = (preferredViewSize.width > 0) ? preferredViewSize.width : kDefaultViewportWidth;
    CGFloat requestedHeight = (preferredViewSize.height > 0) ? preferredViewSize.height : kDefaultViewportHeight;
    CGFloat viewWidth = MIN(contentWidth, requestedWidth);
    CGFloat viewHeight = MIN(contentHeight, requestedHeight);

    viewWidth = MIN(MAX(viewWidth, MIN(kMinimumViewportWidth, maxWidth)), maxWidth);
    viewHeight = MIN(MAX(viewHeight, MIN(kMinimumViewportHeight, maxHeight)), maxHeight);

    [self setFrame:NSMakeRect(0, 0, viewWidth, viewHeight)];

    scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, viewWidth, viewHeight)];
    [scrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:YES];
    [scrollView setAutohidesScrollers:YES];
    [scrollView setBorderType:NSNoBorder];
    [scrollView setDrawsBackground:NO];
    [scrollView setDocumentView:documentView];
    [self addSubview:scrollView];
    NSClipView* clipView = [scrollView contentView];
    CGFloat topOffset = MAX(0.0, contentHeight - NSHeight([clipView bounds]));
    [clipView scrollToPoint:NSMakePoint(0, topOffset)];
    [scrollView reflectScrolledClipView:clipView];

    [documentView release];
    [scrollView release];
    [self setNeedsDisplay:YES];
}

- (BOOL)buildUIIfReady
{
    buildRetryScheduled = false;

    auUI* dspUI = [self dspUI];
    if (!dspUI || !dspUI->boundingBox) {
        [self scheduleBuildRetry];
        return NO;
    }

    [self addParameterListenersForUI:dspUI];

    usesBargraphs = false;
    for (int i = 0; i < dspUI->fUITable.size(); i++)
    {
        if (dspUI->fUITable[i] && dspUI->fUITable[i]->fZone &&
            dynamic_cast<auBargraph*>(dspUI->fUITable[i])) {
            usesBargraphs = true;
            break;
        }
    }

    if (usesBargraphs) {
        monitor = true;
        [self setTimer];
    } else {
        [self unsetTimer];
    }

    if (!uiBuilt) {
        [self repaint];
        uiBuilt = true;
    }

    [self synchronizeUIWithParameterValues];
    return YES;
}

- (void)setAU:(AudioUnit)inAU
{
	if (mAU)
		[self removeListeners];
    
    uiBuilt = false;
    buildRetryScheduled = false;
    viewMap.clear();
    enumValueMap.clear();
    mAU = inAU;
    [self addListeners];
    [self buildUIIfReady];
}

-(void)setTimer
{
    if (!timer)
    {
        timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(update) userInfo:nil repeats:YES];
    }
}

-(void)unsetTimer
{
    if (timer)
    {
        [timer invalidate];
        timer = nil;
    }
}

- (void)update
{
    [self synchronizeUIWithParameterValues];
    [self setNeedsDisplay:YES];
}

// Called upon a knob update
- (void)knobUpdatedWithIndex:(int)index
                   withValue:(double)value
                  withObject:(id)object
{
    [ (FaustAU_Knob*)object setDoubleValue :value ];
    AudioUnitParameterID paramId = (AudioUnitParameterID)[[object identifier] intValue];
    [self applyParameterValue:(Float32)value sender:object parameterID:paramId];
    [object setNeedsDisplay:TRUE];
}

- (void)showHide:(id)sender
{
   	
    int intValue = [sender intValue];
    
    if (intValue)
    {
        [sender setTitle: @"-"];
        [sender setIntValue: 1];
        
        NSBox* box = showHideMap[sender];
        
        [box setHidden:FALSE];
        [box setNeedsDisplay:YES];
    }
    else
    {
        [sender setTitle: @"+"];
        [sender setIntValue: 0];
        
        NSBox* box = showHideMap[sender];
        
        [box setHidden:TRUE];
        [box setNeedsDisplay:YES];
    }
    
    //[self repaint];
}

- (void)buttonPushed:(id)sender
{
    int state =  ((FaustAU_Button*)sender)->buttonState;
    AudioUnitParameterID paramId = (AudioUnitParameterID)[[sender identifier] intValue];
    [self applyParameterValue:(Float32)state sender:sender parameterID:paramId];
}

- (void)buttonEventChanged:(id)sender
{
    NSEventType eventType = [[NSApp currentEvent] type];
    Float32 value = (eventType == NSEventTypeLeftMouseUp) ? 0.0f : 1.0f;
    AudioUnitParameterID paramId = (AudioUnitParameterID)[[sender identifier] intValue];
    [self applyParameterValue:value sender:sender parameterID:paramId];
}

- (void)xmlButtonPushed:(id)sender
{
    NSData *data;
    NSString* dataString;
    NSString *oldString, *newString;
    
    auUI* dspUI = [self dspUI];
    NSFileManager *filemgr = [NSFileManager defaultManager];
    
    NSString* bundlePath = [[NSBundle bundleForClass:[self class]] bundlePath];
    NSString* path = [[[bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"au-output"] stringByAppendingPathExtension:@"xml"];
    
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    NSString *outputFileName = NULL;
    int result = [savePanel runModal];
    
    if (result == NSOKButton){
        outputFileName = [[savePanel URL] path];
    } else {
        return;
    }
    
    data = [filemgr contentsAtPath: path ];
    if (!data) {
        return;
    }
    
    dataString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    for (int i = 0; i < dspUI->fUITable.size(); i++)
    {
        if (dspUI->fUITable[i] && dspUI->fUITable[i]->fZone)
        {
            oldString = [NSString stringWithFormat:@"id=\"%i\"", i + 1];
            newString = [NSString stringWithFormat:@"id=\"%i\" value=\"%f\"", i + 1, *dspUI->fUITable[i]->fZone];
            
            dataString = [dataString stringByReplacingOccurrencesOfString: oldString withString:newString];
        }
    }
    
    data = [dataString dataUsingEncoding:NSUTF8StringEncoding];
    [filemgr createFileAtPath: outputFileName contents: data attributes: nil];
}

- (void)monitorButtonPushed:(id)sender
{
    monitor = [(NSButton*)sender state];
    
    if (monitor)
        [self setTimer];
    else
        [self unsetTimer];
}

- (void)paramChanged:(id)sender
{
    float value =  [sender doubleValue]; //TODO
    AudioUnitParameterID paramId = (AudioUnitParameterID)[[sender identifier] intValue];
    [self applyParameterValue:(Float32)value sender:sender parameterID:paramId];
}

- (void)enumControlChanged:(id)sender
{
    AudioUnitParameterID paramId = (AudioUnitParameterID)[[sender identifier] intValue];
    Float32 value = (Float32)[self valueForEnumSender:sender parameterID:paramId];
    [self applyParameterValue:value sender:sender parameterID:paramId];
}

- (void)synchronizeUIWithParameterValues
{
    auUI* dspUI = [self dspUI];
    if (!dspUI) {
        return;
    }
    
    NSView* subView = NULL;
    int paramId;
    Float32 value;
    
    for (int i = 0; i < dspUI->fUITable.size(); i++)
    {
        if (dspUI->fUITable[i] && dspUI->fUITable[i]->fZone)
        {
            subView = viewMap[i]; //TODO can be used for other cases
            
            if (subView)
            {
                value = *(dspUI->fUITable[i]->fZone);
                [self syncView:subView object:dspUI->fUITable[i] parameterID:i value:value];
            }
        }
    }
}

- (void)eventListener:(void *) inObject event:(const AudioUnitEvent *)inEvent value:(Float32)inValue
{
    if (inEvent->mEventType == kAudioUnitEvent_PropertyChange &&
        inEvent->mArgument.mProperty.mPropertyID == kAudioUnitCustomProperty_dspUI) {
        [self performSelectorOnMainThread:@selector(buildUIIfReady) withObject:nil waitUntilDone:NO];
    } else if (inEvent->mEventType == kAudioUnitEvent_ParameterValueChange ||
               inEvent->mEventType == kAudioUnitEvent_BeginParameterChangeGesture ||
               inEvent->mEventType == kAudioUnitEvent_EndParameterChangeGesture) {
        [self performSelectorOnMainThread:@selector(synchronizeUIWithParameterValues) withObject:nil waitUntilDone:NO];
    }
}

@end
