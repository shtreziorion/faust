#import "FaustAU_Button.h"

@implementation FaustAU_Button

- (FaustAU_Button*)init :(NSRect)frame :(auButton*)fButton :(int)controlId {
    self = [super initWithFrame:frame];
    if (self) {
        buttonState = 0;

        [self setTitle:[[NSString alloc] initWithCString:fButton->fLabel.c_str() encoding:NSUTF8StringEncoding]];
        [self setButtonType:NSMomentaryPushInButton];
        [self setBezelStyle:NSRoundedBezelStyle];

        NSString *identifier = [NSString stringWithFormat:@"%d",controlId];
        [self setIdentifier:identifier];
    }
    return self;
}

- (void)mouseDown:(NSEvent *)theEvent
{
    [self setNeedsDisplay:YES];
    buttonState = 0;
    [self setNeedsDisplay:TRUE];
    [delegate buttonPushed: self];
    
}

- (void)drawRect:(NSRect)rect {
    [super drawRect:[self bounds]];
}

- (void)mouseUp:(NSEvent *)theEvent
{
    buttonState = 1;
    [delegate buttonPushed: self];
    [self setNeedsDisplay:TRUE];
}
@end



