#import "FaustAU_CustomViewFactory.h"
#import "FaustAU_CustomView.h"

static const CGFloat kFactoryMinimumWidth = 360.0;
static const CGFloat kFactoryMinimumHeight = 260.0;
static const CGFloat kFactoryDefaultWidth = 600.0;
static const CGFloat kFactoryDefaultHeight = 380.0;

@implementation FaustAU_CustomViewFactory

- (unsigned) interfaceVersion {
	return 0;
}

// string description of the Cocoa UI
- (NSString *) description {
	return @"Grame: FaustAU";
}

- (NSView *)uiViewForAudioUnit:(AudioUnit)inAU withSize:(NSSize)inPreferredSize {
    NSRect visibleFrame = [[NSScreen mainScreen] visibleFrame];
    CGFloat maxWidth = MAX(kFactoryMinimumWidth, floor(visibleFrame.size.width * 0.7));
    CGFloat maxHeight = MAX(kFactoryMinimumHeight, floor(visibleFrame.size.height * 0.7));
    CGFloat requestedWidth = (inPreferredSize.width > 0) ? inPreferredSize.width : kFactoryDefaultWidth;
    CGFloat requestedHeight = (inPreferredSize.height > 0) ? inPreferredSize.height : kFactoryDefaultHeight;

    inPreferredSize.width = MIN(MAX(requestedWidth, kFactoryMinimumWidth), maxWidth);
    inPreferredSize.height = MIN(MAX(requestedHeight, kFactoryMinimumHeight), maxHeight);

    FaustAU_CustomView *view = [[FaustAU_CustomView alloc] initWithFrame:NSMakeRect(0, 0, inPreferredSize.width, inPreferredSize.height)];
    [view setPreferredSize:inPreferredSize];
    [view setAU:inAU];
    return [view autorelease];
}


@end
