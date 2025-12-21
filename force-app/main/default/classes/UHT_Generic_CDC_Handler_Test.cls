@IsTest
private class UHT_Generic_CDC_Handler_Test {

    @IsTest
    static void testBulkUpdate_MultipleRecords_MultipleFields() {

        // -----------------------
        // Arrange
        // -----------------------
        UHT_Generic_CDC_Handler.testOverrideIsActive = true;

        // Verify shipped metadata exists
        System.assert(
            [SELECT COUNT()
             FROM missionsf__UHT_Tracked_Object__mdt
             WHERE missionsf__ObjectApiName__c = 'Account'] > 0,
            'Account tracked object metadata must exist'
        );

        System.assertEquals(
            2,
            [SELECT COUNT()
             FROM missionsf__UHT_Tracked_Field__mdt
             WHERE missionsf__ObjectApiName__c = 'Account'
               AND missionsf__FieldApiName__c IN ('Industry', 'AnnualRevenue')],
            'Account must have two shipped tracked fields'
        );

        // Seed records
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
        // UPDATE (bulk, multi-field)
        // -----------------------
        a1.Industry = 'Communications';
        a1.AnnualRevenue = 1500000;

        a2.Industry = 'Healthcare';
        a2.AnnualRevenue = 2500000;

        update new List<Account>{ a1, a2 };

        // -----------------------
        // CREATE (CDC-style)
        // -----------------------
        Account a3 = new Account(
            Name = 'Acct C',
            Industry = 'Energy',
            AnnualRevenue = 3000000
        );
        insert a3;

        // -----------------------
        // DELETE
        // -----------------------
        delete a3;

        // -----------------------
        // UNDELETE
        // -----------------------
        undelete a3;

        Test.stopTest();

        // -----------------------
        // Simulated CDC payloads
        // -----------------------
        UHT_Generic_CDC_Handler handler = new UHT_Generic_CDC_Handler();

        // UPDATE payloads
        handler.handle(new UHT_CDC_Handler.CDCContext(
            new Map<String, Object>{
                'Industry' => 'Communications',
                'AnnualRevenue' => 1500000,
                'ChangeEventHeader' => new Map<String, Object>{
                    'entityName' => 'Account',
                    'changeType' => 'UPDATE',
                    'recordIds' => new List<String>{ a1.Id }
                }
            }
        ));

        handler.handle(new UHT_CDC_Handler.CDCContext(
            new Map<String, Object>{
                'Industry' => 'Healthcare',
                'AnnualRevenue' => 2500000,
                'ChangeEventHeader' => new Map<String, Object>{
                    'entityName' => 'Account',
                    'changeType' => 'UPDATE',
                    'recordIds' => new List<String>{ a2.Id }
                }
            }
        ));

        // CREATE payload
        handler.handle(new UHT_CDC_Handler.CDCContext(
            new Map<String, Object>{
                'Industry' => 'Energy',
                'AnnualRevenue' => 3000000,
                'ChangeEventHeader' => new Map<String, Object>{
                    'entityName' => 'Account',
                    'changeType' => 'CREATE',
                    'recordIds' => new List<String>{ a3.Id }
                }
            }
        ));

        // DELETE payload (no field values)
        handler.handle(new UHT_CDC_Handler.CDCContext(
            new Map<String, Object>{
                'ChangeEventHeader' => new Map<String, Object>{
                    'entityName' => 'Account',
                    'changeType' => 'DELETE',
                    'recordIds' => new List<String>{ a3.Id }
                }
            }
        ));

        // UNDELETE payload
        handler.handle(new UHT_CDC_Handler.CDCContext(
            new Map<String, Object>{
                'Industry' => 'Energy',
                'AnnualRevenue' => 3000000,
                'ChangeEventHeader' => new Map<String, Object>{
                    'entityName' => 'Account',
                    'changeType' => 'UNDELETE',
                    'recordIds' => new List<String>{ a3.Id }
                }
            }
        ));

        // Flush buffered intents
        UHT_Generic_CDC_Handler.flush();

        // -----------------------
        // Assert
        // -----------------------
        List<missionsf__UHT_Change_Log__c> logs = [
            SELECT
                missionsf__Tracked_Record_Id__c,
                missionsf__Tracked_Field__c,
                missionsf__New_Value__c,
                missionsf__Change_Type__c
            FROM missionsf__UHT_Change_Log__c
        ];

        System.debug('Change Logs: ' + logs);

        // Expected minimum:
        // - 4 from UPDATE (2 records × 2 fields)
        // - 2 from CREATE
        // - 2 from DELETE
        // - 2 from UNDELETE
        System.assert(
            logs.size() >= 10,
            'Expected change logs for UPDATE, CREATE, DELETE, and UNDELETE'
        );
    }
}
