//
//  Process.m
//  LaunchRocket
//
//  Created by Josh Butts on 1/24/14.
//  Copyright (c) 2014 Josh Butts. All rights reserved.
//

#import <AppKit/AppKit.h>
#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <libproc.h>
#include <pwd.h>
#import "Process.h"
#import "Service.h"

NSTask *task = nil;
@implementation Process

- (id) initWithAuthProvider:(id<AuthorizationProvider>) auth {
    if ( self = [self init] ) {
        self->auth = auth;
    }
    return self;
}

// Executes a batch of commands using the helper app.
- (BOOL) runHelperTaskList:(NSArray *)argList {
    int res = [self->auth runHelperAsRootWithArgs:argList];
    if (res != 0) {
        NSLog(@"Error: running helper with args `%@` failed with code %d", [argList componentsJoinedByString:@" "], res);
        return NO;
    }
    
    return YES;
}

- (void) runTaskAsync:(NSString *)argument from:(NSString *)workingDirectory {

    if ( task != nil ) {
        [task terminate];
    }

    NSPipe *output = [NSPipe pipe];
    task = [[NSTask alloc] init];

    task.currentDirectoryPath = workingDirectory;
    task.launchPath = @"/bin/bash";
    task.arguments = @[@"-c", argument];

    [task setStandardError:output];
    [task setStandardOutput:output];
    [task setTerminationHandler:^(NSTask *task){
        const char *result = [[output.fileHandleForReading readDataToEndOfFile] bytes];
        DLog(@"Result of `%@` was %@", argument, result!=NULL?[NSString stringWithUTF8String:result]:@"NULL");
        task = nil;
        
    }];
    
    // Fire and forget
    [task launch];
}

typedef struct kinfo_proc kinfo_proc;
static int GetBSDProcessList(kinfo_proc **procList, size_t *procCount)
// Returns a list of all BSD processes on the system.  This routine
// allocates the list and puts it in *procList and a count of the
// number of entries in *procCount.  You are responsible for freeing
// this list (use "free" from System framework).
// On success, the function returns 0.
// On error, the function returns a BSD errno value.
{
    int                 err;
    kinfo_proc *        result;
    bool                done;
    static const int    name[] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    // Declaring name as const requires us to cast it when passing it to
    // sysctl because the prototype doesn't include the const modifier.
    size_t              length;
    
    //    assert( procList != NULL);
    //    assert(*procList == NULL);
    //    assert(procCount != NULL);
    
    *procCount = 0;
    
    // We start by calling sysctl with result == NULL and length == 0.
    // That will succeed, and set length to the appropriate length.
    // We then allocate a buffer of that size and call sysctl again
    // with that buffer.  If that succeeds, we're done.  If that fails
    // with ENOMEM, we have to throw away our buffer and loop.  Note
    // that the loop causes use to call sysctl with NULL again; this
    // is necessary because the ENOMEM failure case sets length to
    // the amount of data returned, not the amount of data that
    // could have been returned.
    
    result = NULL;
    done = false;
    do {
        assert(result == NULL);
        
        // Call sysctl with a NULL buffer.
        
        length = 0;
        err = sysctl( (int *) name, (sizeof(name) / sizeof(*name)) - 1, NULL, &length, NULL, 0);
        if (err == -1) {
            err = errno;
        }
        
        // Allocate an appropriately sized buffer based on the results
        // from the previous call.
        
        if (err == 0) {
            result = malloc(length);
            if (result == NULL) {
                err = ENOMEM;
            }
        }
        
        // Call sysctl again with the new buffer.  If we get an ENOMEM
        // error, toss away our buffer and start again.
        
        if (err == 0) {
            err = sysctl( (int *) name, (sizeof(name) / sizeof(*name)) - 1, result, &length, NULL, 0);
            if (err == -1) {
                err = errno;
            }
            if (err == 0) {
                done = true;
            } else if (err == ENOMEM) {
                assert(result != NULL);
                free(result);
                result = NULL;
                err = 0;
            }
        }

    } while (err == 0 && ! done);
    
    // Clean up and establish post conditions.
    
    if (err != 0 && result != NULL) {
        free(result);
        result = NULL;
    }
    *procList = result;
    if (err == 0) {
        *procCount = length / sizeof(kinfo_proc);
    }
    
    assert( (err == 0) == (*procList != NULL) );
    return err;
}

/**
    see https://stackoverflow.com/questions/12273546/get-name-from-pid/12274588#12274588
 */
static char* getBSDProcessName( pid_t pid ) {

    char pathBuffer [PROC_PIDPATHINFO_MAXSIZE];
    proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));

    long strLen = strlen(pathBuffer);
    long position = strLen;
    while(position >= 0 && pathBuffer[position] != '/')
    {
        position--;
    }

    char *nameBuffer = (char *) malloc(sizeof(char) * ( strLen - position +1 ));
    strcpy(nameBuffer, pathBuffer + position + 1);
    return nameBuffer;
}

+ (NSArray*)getBSDProcessList
{
    kinfo_proc *mylist =NULL;
    size_t mycount = 0;
    GetBSDProcessList(&mylist, &mycount);
    
    NSMutableArray *processes = [NSMutableArray arrayWithCapacity:(int)mycount];
    
    for (int i = 0; i < mycount; i++) {
        struct kinfo_proc *currentProcess = &mylist[i];
        struct passwd *user = getpwuid(currentProcess->kp_eproc.e_ucred.cr_uid);
        NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithCapacity:4];
        
        NSNumber *processID = [NSNumber numberWithInt:currentProcess->kp_proc.p_pid];
        NSString *processName = [NSString stringWithFormat: @"%s",currentProcess->kp_proc.p_comm];

        if (processID) {
            [entry setObject:processID forKey:@"processID"];
            
            // if there is a process id we'll try to figure out the process name using another function
            // the reason is, that the kinfo_proc->p_comm is shortened and even ps uses this kind of API to retrieve the full name.
            processName = [NSString stringWithFormat: @"%s",getBSDProcessName(currentProcess->kp_proc.p_pid)];
        }

        if (processName)[entry setObject:processName forKey:@"processName"];
        
        if (user){
            NSNumber *userID = [NSNumber numberWithUnsignedInt:currentProcess->kp_eproc.e_ucred.cr_uid];
            NSString *userName = [NSString stringWithFormat: @"%s",user->pw_name];
            
            if (userID)[entry setObject:userID forKey:@"userID"];
            if (userName)[entry setObject:userName forKey:@"userName"];
        }
        
        [processes addObject:[NSDictionary dictionaryWithDictionary:entry]];
    }
    free(mylist);

    return [NSArray arrayWithArray:processes];
}

+ (NSDictionary*)getProcessByService:(Service *)service {
    
    for ( NSDictionary *process in [Process getBSDProcessList] ) {

        if ( [[process objectForKey:@"processName"] isEqualToString:[[service program] lastPathComponent]] ) {
            NSString *path = @"/bin/ps";
            NSArray *args = [NSArray arrayWithObjects:@"-o", @"command=",[(NSNumber*)[process objectForKey:@"processID"] stringValue], nil];
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:path];
            [task setArguments:args];
            
            [task setStandardInput:[NSPipe pipe]];
            [task setStandardOutput:[NSPipe pipe]];
            [task launch];
            [task waitUntilExit];

            NSData *outputData = [[[task standardOutput] fileHandleForReading] availableData];
            NSString* command = [[NSString alloc] initWithData:outputData encoding:NSASCIIStringEncoding];
            command = [command substringToIndex:MIN(service.program.length,command.length)];
//*
            // NOOP
/*/
            DLog(@"Arguments: %@", args);
            DLog(@"Output: '%s'", outputData.bytes);
            DLog(@"Looking for PR: '%@'", service.program);
            DLog(@"Found Programm: '%@'", command);
//*/
            if ( command.length >= service.program.length && [service.program isEqualToString:command]) {
                NSMutableDictionary* mProcess = [process mutableCopy];
                
                // Trim
                [mProcess setObject:command forKey:@"fullProcessName"];
                return mProcess;
            }
        }
    }
    
    return nil;
}

@end
