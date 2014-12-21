//
//  ViewController.h
//  Deadlocketector
//
//  Created by Lukasz Margielewski on 21/12/2014.
//  Copyright (c) 2014 Lukasz Margielewski. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface ViewController : UIViewController

@property (nonatomic, strong) IBOutlet UILabel *cpuPercentLabel;

@property (nonatomic, strong) IBOutlet UILabel *timerLabelLow;
@property (nonatomic, strong) IBOutlet UILabel *timerLabelDef;
@property (nonatomic, strong) IBOutlet UILabel *timerLabelBack;
@property (nonatomic, strong) IBOutlet UILabel *timerLabelHigh;

-(IBAction)stopWatchdog:(id)sender;
-(IBAction)startWatchdog:(id)sender;

-(IBAction)scheduleDeadlock:(id)sender;

@end

