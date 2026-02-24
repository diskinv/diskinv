//
//  NTTitledInfoPair.h
//  CocoaTechBase
//
//  Created by Steve Gehrman on Thu Dec 11 2003.
//  Copyright (c) 2003 __MyCompanyName__. All rights reserved.
//

@interface NTTitledInfoPair : NSObject
{
    NSString* _title;
    NSString* _info;
    
    SEL _action;
    id _target;
}

// pass nil to edit action if you don't want it editable
+ (id)infoPair:(NSString*)title info:(NSString*)info;
+ (id)infoPair:(NSString*)title info:(NSString*)info action:(SEL)action target:(id)target;

- (NSString*)title;
- (NSString*)info;

- (SEL)action;
- (id)target;
@end
