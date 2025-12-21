@IsTest
private class UHT_Generic_CDC_Handler_Test {

    @IsTest
    static void testBulkUpdate_MultipleRecords_MultipleFields() {

        // -----------------------
        // Arrange
        // -----------------------

        // Verify metadata exists (sanity check)
        System.assert(
            [SELECT COUNT()
             FROM missionsf__UHT_Tracked_Object__mdt
             WHERE IsActive__c = true AND missionsf__ObjectApiName__c = 'Account'] > 0,
            'Account must be tracked via CMDT'
        );

        System.assertEquals(
            2,
            [SELECT COUNT()
             FROM missionsf__UHT_Tracked_Field__mdt
             WHERE IsActive__c = true AND missionsf__ObjectApiName__c = 'Account'],
            'Account must have exactly two tracked fields for this test'
        );

        // Seed data
        Account a1 = new Account(
            Name = 'Acct A',
            Industry = 'Manufacturing',
            AnnualRevenue = 1000000
        );
        Account a2 = new Account(
            Name = 'Acct B',
            Industry = 'Technology',
            AnnualRevenue = 2000000
        );
        insert new List<Account>{ a1, a2 };

        Test.startTest();

        // -----------------------
        // Act
        // -----------------------

        a1.Industry = 'Communications';
        a1.AnnualRevenue = 1500000;

        a2.Industry = 'Healthcare';
        a2.AnnualRevenue = 2500000;

        update new List<Account>{ a1, a2 };

        Test.stopTest();

        // -----------------------
        // Assert
        // -----------------------

        List<missionsf__UHT_Change_Log__c> logs = [
            SELECT
                missionsf__Tracked_Record_Id__c,
                missionsf__Tracked_Field__c,
                missionsf__Old_Value__c,
                missionsf__New_Value__c,
                missionsf__Change_Type__c
            FROM missionsf__UHT_Change_Log__c
        ];

        System.assertEquals(
            4,
            logs.size(),
            'Expected 4 change log rows (2 records × 2 fields)'
        );

        Map<String, missionsf__UHT_Change_Log__c> byKey = new Map<String, missionsf__UHT_Change_Log__c>();
        for (missionsf__UHT_Change_Log__c l : logs) {
            byKey.put(l.missionsf__Tracked_Record_Id__c + ':' + l.missionsf__Tracked_Field__c, l);
        }

        // Account 1
        System.assertEquals(
            'Manufacturing',
            byKey.get(a1.Id + ':Industry').missionsf__Old_Value__c
        );
        System.assertEquals(
            'Communications',
            byKey.get(a1.Id + ':Industry').missionsf__New_Value__c
        );

        System.assertEquals(
            '1000000',
            byKey.get(a1.Id + ':AnnualRevenue').missionsf__Old_Value__c
        );
        System.assertEquals(
            '1500000',
            byKey.get(a1.Id + ':AnnualRevenue').missionsf__New_Value__c
        );

        // Account 2
        System.assertEquals(
            'Technology',
            byKey.get(a2.Id + ':Industry').missionsf__Old_Value__c
        );
        System.assertEquals(
            'Healthcare',
            byKey.get(a2.Id + ':Industry').missionsf__New_Value__c
        );

        System.assertEquals(
            '2000000',
            byKey.get(a2.Id + ':AnnualRevenue').missionsf__Old_Value__c
        );
        System.assertEquals(
            '2500000',
            byKey.get(a2.Id + ':AnnualRevenue').missionsf__New_Value__c
        );
    }
}
