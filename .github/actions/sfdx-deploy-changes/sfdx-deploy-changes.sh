#!/bin/sh

targetEnv=$1
buildType=$2
testSettingsFolder=./build-settings/mandatoryTests

validateOption=""
if [ "$buildType" = "Check" ]; then
    validateOption="-c"
fi

# Get a list of cls files in the specified folder as a comma-separated list
getClassesFromFolder() {
    baseFolder=$1
    testExt=$2
    folderClasses=""
    rawClasses=""
    if [ -d "$baseFolder" ]; then
        rawClasses=$(find $baseFolder \( -name "*.cls" \) -exec basename {} \; | tr '\n' ',')
        ## Transform the classes found to remove any duplicates by
        ##   1. Replace test extension .cls, with _Test{newline}
        ##   2. Replace .cls, with _Test{newline}
        ##   3. Sort the list and remove duplicates
        ##   4. Replace {newline} with ,
        ##   5. Remove the trailing comma
        folderClasses="$(echo $rawClasses | sed s/"$testExt.cls,"/"$testExt\n"/g | sed s/".cls,"/"$testExt\n"/g | sort -u | tr '\n' ',' | sed 's/,$//' | sed 's/^,//' )"
    fi
}

# Get any mandatory object based tests as a comma-separated list
getMandatoryTestsForObject() {
    objectName=$1
    objectTests=""
    if [ -f "$testSettingsFolder/$objectNameTests" ]; then
        objectTests=$(cat $testSettingsFolder/$objectNameTests | tr -d '\r' | sort -u | sed '/^$/d;:a;N;$!ba;s/\n/,/g')
    fi
}

# Get all the system and object mandatory tests as a comma-separated list
getMandatoryTests() {
    deployedObjectFolder=$1

    ## Get any system wide mandatory tests as a comma-separated list
    mandatoryTests=$(cat $testSettingsFolder/.globalTests | tr -d '\r' | sort -u | sed '/^$/d;:a;N;$!ba;s/\n/,/g')
    echo -e "$YELLOW_TEXT -> Default Mandatory Tests:${BLUE_TEXT} ${mandatoryTests}"

    if [ -d $deployedObjectFolder/objects ]; then

        for f in $deployedObjectFolder/objects/*; do
            if [ -d "$f" ]; then
                # Will not run if no directories are available
                objectName="$(basename $f)"

                # Get the object mandatory if there are any
                getMandatoryTestsForObject $objectName
                if [ ! -z $objectTests ]; then
                    mandatoryTests="$mandatoryTests,$objectTests"
                    echo -e "$YELLOW_TEXT - $objectName Mandatory Tests:${BLUE_TEXT} $objectTests"
                fi
            fi
        done
    fi
}

# Get all the test to run as a unique sorted comma-separated list
getTestClassList() {

    getClassesFromFolder "$DEPLOY_FOLDER/$FORCE_APP_FOLDER/fflib-common" "Test"
    aefCommonClasses=$folderClasses
    echo -e "$YELLOW_TEXT -> Apex Common Tests:$BLUE_TEXT ${aefCommonClasses}"

    getClassesFromFolder "$DEPLOY_FOLDER/$FORCE_APP_FOLDER/fflib-mocks" "Test"
    aefMocksClasses=$folderClasses
    echo -e "$YELLOW_TEXT -> Apex Mocks Tests:$BLUE_TEXT ${aefMocksClasses}"

    getClassesFromFolder "$DEPLOY_FOLDER/$FORCE_APP_FOLDER/main" "Test"
    mainClasses=$folderClasses
    echo -e "$YELLOW_TEXT -> Main Tests:$BLUE_TEXT ${mainClasses}"

    getMandatoryTests "$DEPLOY_FOLDER/$FORCE_APP_FOLDER/main"

    allClasses=$mandatoryTests,$aefCommonClasses,$aefMocksClasses,$mainClasses

    ## Transform the classes found to remove any duplicates
    testsToRun="$(echo $allClasses | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//' | sed 's/^,//' )"

}

getDestructiveOption() {
    ## Check for and remove artifacts with destructive changes if needed
    numberOfLines=$(wc -l < $DEPLOY_FOLDER/destructiveChanges/destructiveChanges.xml )
    destructiveOption=""
    if [ "$numberOfLines" -gt 4 ]; then
        ignoreErrors="--ignoreerrors"
        if [ "$targetEnv" = "production" ]; then
            ignoreErrors=""
        fi
        destructiveOption="--ignorewarnings $ignoreErrors --postdestructivechanges $DEPLOY_FOLDER/destructiveChanges/destructiveChanges.xml"
    fi
}

getDestructiveOption

## Deploy changes to Salesforce only if there is something to deploy
if [[ -d "$DEPLOY_FOLDER/$FORCE_APP_FOLDER" ]] || [[ ! -z "$destructiveOption" ]] ; then

    echo -e "Tests to run:"
    getTestClassList

    testsOption="-l RunSpecifiedTests -r $testsToRun"
    if [ -z "$testsToRun" ]; then
        testsOption=""
    fi

    if [ "$buildType" == "Deploy" ]; then
        echo -e "$BLUE_TEXT Running Command:$YELLOW_TEXT sfdx force:apex:execute -f build-settings/scripts/current-release-pre.apex"
        sfdx force:apex:execute -f build-settings/scripts/current-release-pre.apex
    fi

    echo -e "$BLUE_TEXT Running Command:$YELLOW_TEXT sfdx force:source:deploy -x $DEPLOY_FOLDER/package/package.xml --verbose $validateOption $testsOption $destructiveOption"
    sfdx force:source:deploy -x $DEPLOY_FOLDER/package/package.xml --verbose $validateOption $testsOption $destructiveOption
    if [ "$?" -ne "0" ]; then
        echo -e "$RED_TEXT----> Deployment to [$targetEnv] FAILED."
        exit 1
    fi

    if [ "$buildType" == "Deploy" ]; then
        echo -e "$BLUE_TEXT Running Command:$YELLOW_TEXT sfdx force:apex:execute -f build-settings/scripts/current-release-post.apex"
        sfdx force:apex:execute -f build-settings/scripts/current-release-post.apex
    fi

    echo -e "$GREEN_TEXT----> Deployment to [$targetEnv] successful."
else
    echo -e "$GREEN_TEXT----> Nothing to deploy to [$targetEnv]."
fi
