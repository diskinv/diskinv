//
//  NTTitledInfoPair.m
//  CocoaTechBase
//
//  Created by Steve Gehrman on Thu Dec 11 2003.
//  Copyright (c) 2003 __MyCompanyName__. All rights reserved.
//

#import "NTTitledInfoPair.h"

@implementation NTTitledInfoPair

// pass nil to edit action if you don't want it editable
- (id)initWithTitle:(NSString*)title info:(NSString*)info action:(SEL)action target:(id)target;
{
    self = [super init];
    
    _title = [title retain];
    _info = [info retain];
    _action = action;
    _target = target;
    
    return self;
}

+ (id)infoPair:(NSString*)title info:(NSString*)info;
{
    return [self infoPair:title info:info action:0 target:nil];
}

+ (id)infoPair:(NSString*)title info:(NSString*)info action:(SEL)action target:(id)target;
{
    NTTitledInfoPair *result = [[NTTitledInfoPair alloc] initWithTitle:title info:info action:action target:target];
    
    return [result autorelease];    
}

- (void)dealloc;
{
    [_title release];
    [_info release];
    
    [super dealloc];
}

- (NSString*)title;
{
    return _title;
}

- (NSString*)info;
{
    return _info;
}

- (SEL)action;
{
    return _action;
}

- (id)target;
{
    return _target;
}

@end
