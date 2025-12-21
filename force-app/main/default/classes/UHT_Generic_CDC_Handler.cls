public with sharing class UHT_Generic_CDC_Handler extends UHT_CDC_Handler {

    @TestVisible
    static Boolean testOverrideIsActive = false;

    // -----------------------
    // Intent buffering
    // -----------------------

    private class EventIntent {
        String objectName;
        String recordId;
        String changeType;
        Datetime commitTimestamp;
        String commitUserId;
        String commitNumber;
        Map<String, Object> rawPayload;
    }

    private class FieldIntent {
        String objectName;
        String recordId;
        String fieldName;
        String changeType;
        Datetime commitTimestamp;
        String commitUserId;
        String commitNumber;
        String newValue;
    }

    // buffer is static so it survives per-event calls within the same transaction
    private static List<EventIntent> pending = new List<EventIntent>();

    // -----------------------
    // CDC lifecycle hooks
    // -----------------------

    protected override void handleCreate(CDCContext ctx) {
        collect(ctx);
    }

    protected override void handleUpdate(CDCContext ctx) {
        collect(ctx);
    }

    protected override void handleDelete(CDCContext ctx) {
        collect(ctx);
    }

    protected override void handleUndelete(CDCContext ctx) {
        collect(ctx);
    }

    private static void collect(CDCContext ctx) {
        if (ctx == null || String.isBlank(ctx.entityName) || ctx.recordId == null) return;

        EventIntent i = new EventIntent();
        i.objectName = ctx.entityName;
        i.recordId = String.valueOf(ctx.recordId);
        i.changeType = ctx.changeType;
        i.commitTimestamp = ctx.commitTimestamp;
        i.commitUserId = ctx.commitUserId;
        i.commitNumber = ctx.commitNumber;
        i.rawPayload = ctx.rawPayload;

        pending.add(i);
    }

    // -----------------------
    // Flush (bulk-safe)
    // -----------------------

    public static void flush() {
        if (pending.isEmpty()) return;

        // Always clear the buffer no matter what, so we don't leak state between invocations
        List<EventIntent> batch = pending;
        pending = new List<EventIntent>();

        // 1) Determine which objects are tracked (presence = enabled)
        Set<String> objectNames = new Set<String>();
        for (EventIntent e : batch) objectNames.add(e.objectName);

        Set<String> trackedObjects = new Set<String>();
        for (missionsf__UHT_Tracked_Object__mdt o : [
            SELECT missionsf__ObjectApiName__c, IsActive__c
            FROM missionsf__UHT_Tracked_Object__mdt
            WHERE missionsf__ObjectApiName__c IN :objectNames
        ]) {
            // 🔒 Activation guard (install-safe)
            if (!testOverrideIsActive && !o.IsActive__c) {
                continue;
            }
            trackedObjects.add(o.missionsf__ObjectApiName__c);
        }

        if (trackedObjects.isEmpty()) return;

        // 2) Load tracked fields for those objects
        Map<String, Set<String>> trackedFieldsByObject = new Map<String, Set<String>>();
        for (String objName : trackedObjects) trackedFieldsByObject.put(objName, new Set<String>());

        for (missionsf__UHT_Tracked_Field__mdt f : [
            SELECT missionsf__ObjectApiName__c, missionsf__FieldApiName__c, IsActive__c
            FROM missionsf__UHT_Tracked_Field__mdt
            WHERE missionsf__ObjectApiName__c IN :trackedObjects
        ]) {
            if (!testOverrideIsActive && !f.IsActive__c) {
                continue;
            }
            trackedFieldsByObject.get(f.missionsf__ObjectApiName__c).add(f.missionsf__FieldApiName__c);
        }

        // 3) Expand event intents into field intents (what we will actually persist)
        List<FieldIntent> fieldIntents = new List<FieldIntent>();

        for (EventIntent e : batch) {
            if (!trackedObjects.contains(e.objectName)) continue;

            Set<String> trackedFields = trackedFieldsByObject.get(e.objectName);
            if (trackedFields == null || trackedFields.isEmpty()) continue;

            // DELETE events often don't include field values. We still want to log per tracked field.
            if (e.changeType == 'DELETE') {
                for (String tf : trackedFields) {
                    FieldIntent fi = new FieldIntent();
                    fi.objectName = e.objectName;
                    fi.recordId = e.recordId;
                    fi.fieldName = tf;
                    fi.changeType = e.changeType;
                    fi.commitTimestamp = e.commitTimestamp;
                    fi.commitUserId = e.commitUserId;
                    fi.commitNumber = e.commitNumber;
                    fi.newValue = null; // deleted
                    fieldIntents.add(fi);
                }
                continue;
            }

            // CREATE / UPDATE / UNDELETE: persist only fields present in the CDC payload (changed/populated)
            if (e.rawPayload == null) continue;

            for (String fieldName : e.rawPayload.keySet()) {
                if (isSystemField(fieldName)) continue;
                if (!trackedFields.contains(fieldName)) continue;

                Object v = e.rawPayload.get(fieldName);
                if (v == null) continue;

                FieldIntent fi = new FieldIntent();
                fi.objectName = e.objectName;
                fi.recordId = e.recordId;
                fi.fieldName = fieldName;
                fi.changeType = e.changeType;
                fi.commitTimestamp = e.commitTimestamp;
                fi.commitUserId = e.commitUserId;
                fi.commitNumber = e.commitNumber;
                fi.newValue = String.valueOf(v);
                fieldIntents.add(fi);
            }
        }

        if (fieldIntents.isEmpty()) return;

        // 4) Bulk query prior logs (old value reconstruction)
        Set<String> recordIds = new Set<String>();
        Set<String> fieldNames = new Set<String>();
        for (FieldIntent fi : fieldIntents) {
            recordIds.add(fi.recordId);
            fieldNames.add(fi.fieldName);
        }

        // We will keep "most recent per (object|record|field)" by ordering DESC and only taking first.
        Map<String, missionsf__UHT_Change_Log__c> priorByKey = new Map<String, missionsf__UHT_Change_Log__c>();

        for (missionsf__UHT_Change_Log__c row : [
            SELECT missionsf__Tracked_Object__c,
                   missionsf__Tracked_Record_Id__c,
                   missionsf__Tracked_Field__c,
                   missionsf__New_Value__c,
                   missionsf__Change_Timestamp__c
            FROM missionsf__UHT_Change_Log__c
            WHERE missionsf__Tracked_Object__c IN :trackedObjects
              AND missionsf__Tracked_Record_Id__c IN :recordIds
              AND missionsf__Tracked_Field__c IN :fieldNames
            ORDER BY missionsf__Change_Timestamp__c DESC
        ]) {
            String k = makeKey(row.missionsf__Tracked_Object__c, row.missionsf__Tracked_Record_Id__c, row.missionsf__Tracked_Field__c);
            if (!priorByKey.containsKey(k)) {
                priorByKey.put(k, row);
            }
        }

        // 5) Bulk insert new logs
        List<missionsf__UHT_Change_Log__c> toInsert = new List<missionsf__UHT_Change_Log__c>();

        for (FieldIntent fi : fieldIntents) {
            String k = makeKey(fi.objectName, fi.recordId, fi.fieldName);
            missionsf__UHT_Change_Log__c prior = priorByKey.get(k);

            String oldValue = (prior != null) ? prior.missionsf__New_Value__c : null;

            toInsert.add(new missionsf__UHT_Change_Log__c(
                missionsf__Tracked_Object__c     = fi.objectName,
                missionsf__Tracked_Record_Id__c  = fi.recordId,
                missionsf__Tracked_Field__c      = fi.fieldName,
                missionsf__Change_Type__c        = fi.changeType,
                missionsf__Old_Value__c          = oldValue,
                missionsf__New_Value__c          = fi.newValue,

                // Safe defaults for test + non-CDC edge cases
                missionsf__Change_Timestamp__c   = fi.commitTimestamp != null
                    ? fi.commitTimestamp
                    : System.now(),

                missionsf__Commit_User_Id__c     = String.isNotBlank(fi.commitUserId)
                    ? fi.commitUserId
                    : UserInfo.getUserId(),

                missionsf__Commit_Number__c      = fi.commitNumber != null
                    ? fi.commitNumber
                    : 'TEST'
            ));

        }

        insert toInsert;
    }

    // -----------------------
    // Helpers
    // -----------------------

    private static Boolean isSystemField(String fieldName) {
        return fieldName == 'ChangeEventHeader'
            || fieldName == 'ReplayId'
            || fieldName == 'Id'
            || fieldName == 'LastModifiedDate';
    }

    private static String makeKey(String obj, String rid, String field) {
        return obj + '|' + rid + '|' + field;
    }
}
