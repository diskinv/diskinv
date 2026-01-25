//
//  MyDocumentController.h
//  Disk Accountant
//
//  Created by Tjark Derlien on Wed Oct 08 2003.
//
//  Copyright (C) 2003 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.
//

//

#import <Foundation/Foundation.h>


@interface MyDocumentController : NSDocumentController
{
	IBOutlet NSMenu* _zoomStackMenu;
	IBOutlet NSPanel* _donationPanel;
}

- (IBAction) showPreferencesPanel: (id) sender;
- (IBAction) gotoHomepage: (id) sender;
- (IBAction) closeDonationPanel: (id) sender;

- (void) openDocumentWithContentsOfFile: (NSString*) fileName; //calls "openDocumentWithContentsOfFile: fileName display: [self shouldCreateUI]"
@end
