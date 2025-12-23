import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAvailableObjects from '@salesforce/apex/UHT_AdminController.getAvailableObjects';
import getObjectFields from '@salesforce/apex/UHT_AdminController.getObjectFields';
import saveTrackedConfiguration from '@salesforce/apex/UHT_AdminController.saveTrackedConfiguration';

export default class UhtAdminConsole extends LightningElement {
    @track objects = [];
    @track fieldsByObject = {};
    @track isLoading = true;
    @track isSaving = false;
    @track expandedObjectName = null;

    // Track original state from database for delta comparison
    originalTrackedObjects = new Set();
    originalTrackedFields = {}; // { objectApiName: Set of fieldApiNames }

    connectedCallback() {
        this.loadObjects();
    }

    async loadObjects() {
        this.isLoading = true;
        try {
            const result = await getAvailableObjects();
            
            // Reset original state trackers
            this.originalTrackedObjects = new Set();
            this.originalTrackedFields = {};
            
            this.objects = result.map(obj => {
                // Track original state
                if (obj.isTracked) {
                    this.originalTrackedObjects.add(obj.apiName);
                }
                
                return {
                    ...obj,
                    isSelected: obj.isTracked,
                    isExpanded: false,
                    expandIcon: 'utility:chevronright',
                    fieldsDisabled: !obj.isTracked,
                    fieldsLoaded: false,
                    fields: []
                };
            });
        } catch (error) {
            this.showToast('Error', this.getErrorMessage(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async loadFieldsForObject(objectApiName) {
        const objIndex = this.objects.findIndex(o => o.apiName === objectApiName);
        if (objIndex === -1) return;

        // Already loaded
        if (this.objects[objIndex].fieldsLoaded) return;

        try {
            const fields = await getObjectFields({ objectApiName });
            
            // Track original field state
            this.originalTrackedFields[objectApiName] = new Set(
                fields.filter(f => f.isTracked).map(f => f.apiName)
            );
            
            // Create new array to trigger reactivity
            this.objects = this.objects.map((obj, idx) => {
                if (idx === objIndex) {
                    return {
                        ...obj,
                        fieldsLoaded: true,
                        fields: fields.map(f => ({
                            ...f,
                            isSelected: f.isTracked
                        }))
                    };
                }
                return obj;
            });
        } catch (error) {
            this.showToast('Error', this.getErrorMessage(error), 'error');
        }
    }

    handleObjectClick(event) {
        const objectApiName = event.currentTarget.dataset.objectName;
        const obj = this.objects.find(o => o.apiName === objectApiName);

        if (!obj) return;

        // Toggle expansion
        const isCurrentlyExpanded = obj.isExpanded;
        
        // Collapse all, then expand clicked one (accordion behavior)
        this.objects = this.objects.map(o => {
            const newExpanded = o.apiName === objectApiName ? !isCurrentlyExpanded : false;
            return {
                ...o,
                isExpanded: newExpanded,
                expandIcon: newExpanded ? 'utility:chevrondown' : 'utility:chevronright'
            };
        });

        // Load fields if expanding and not already loaded
        if (!isCurrentlyExpanded && !obj.fieldsLoaded) {
            this.loadFieldsForObject(objectApiName);
        }
    }

    handleObjectCheckboxChange(event) {
        event.stopPropagation();
        const objectApiName = event.target.dataset.objectName;
        const isChecked = event.target.checked;
        const obj = this.objects.find(o => o.apiName === objectApiName);

        if (!obj) return;

        // Update selection
        this.objects = this.objects.map(o => {
            if (o.apiName === objectApiName) {
                return {
                    ...o,
                    isSelected: isChecked,
                    fieldsDisabled: !isChecked,
                    // Clear field selections if unchecking object
                    fields: isChecked ? o.fields : o.fields.map(f => ({ ...f, isSelected: false }))
                };
            }
            return o;
        });

        // Auto-expand if selecting and not expanded
        if (isChecked) {
            const updatedObj = this.objects.find(o => o.apiName === objectApiName);
            if (!updatedObj.isExpanded) {
                this.handleObjectClick({ currentTarget: { dataset: { objectName: objectApiName } } });
            }
        }
    }

    handleFieldCheckboxChange(event) {
        event.stopPropagation();
        const objectApiName = event.target.dataset.objectName;
        const fieldApiName = event.target.dataset.fieldName;
        const isChecked = event.target.checked;

        this.objects = this.objects.map(obj => {
            if (obj.apiName === objectApiName) {
                return {
                    ...obj,
                    fields: obj.fields.map(f => {
                        if (f.apiName === fieldApiName) {
                            return { ...f, isSelected: isChecked };
                        }
                        return f;
                    })
                };
            }
            return obj;
        });
    }

    handleSelectAllFields(event) {
        const objectApiName = event.target.dataset.objectName;
        
        this.objects = this.objects.map(obj => {
            if (obj.apiName === objectApiName) {
                const allSelected = obj.fields.every(f => f.isSelected);
                return {
                    ...obj,
                    fields: obj.fields.map(f => ({ ...f, isSelected: !allSelected }))
                };
            }
            return obj;
        });
    }

    async handleSave() {
        this.isSaving = true;

        try {
            // Compute delta: what's changed from original state
            const objectsToActivate = [];
            const objectsToDeactivate = [];
            const fieldsToActivate = {};   // { objectApiName: [fieldNames] }
            const fieldsToDeactivate = {}; // { objectApiName: [fieldNames] }

            this.objects.forEach(obj => {
                const currentlySelected = obj.isSelected;
                const wasOriginallyTracked = this.originalTrackedObjects.has(obj.apiName);
                
                // Object-level changes
                if (currentlySelected && !wasOriginallyTracked) {
                    objectsToActivate.push(obj.apiName);
                } else if (!currentlySelected && wasOriginallyTracked) {
                    objectsToDeactivate.push(obj.apiName);
                }

                // Field-level changes (only if fields were loaded)
                if (obj.fieldsLoaded) {
                    const originalFields = this.originalTrackedFields[obj.apiName] || new Set();
                    
                    const newlySelectedFields = [];
                    const newlyDeselectedFields = [];

                    obj.fields.forEach(field => {
                        const isNowSelected = field.isSelected;
                        const wasOriginallySelected = originalFields.has(field.apiName);

                        if (isNowSelected && !wasOriginallySelected) {
                            newlySelectedFields.push(field.apiName);
                        } else if (!isNowSelected && wasOriginallySelected) {
                            newlyDeselectedFields.push(field.apiName);
                        }
                    });

                    if (newlySelectedFields.length > 0) {
                        fieldsToActivate[obj.apiName] = newlySelectedFields;
                    }
                    if (newlyDeselectedFields.length > 0) {
                        fieldsToDeactivate[obj.apiName] = newlyDeselectedFields;
                    }
                }
            });

            // Check if there are any changes
            const hasObjectChanges = objectsToActivate.length > 0 || objectsToDeactivate.length > 0;
            const hasFieldChanges = Object.keys(fieldsToActivate).length > 0 || 
                                   Object.keys(fieldsToDeactivate).length > 0;

            if (!hasObjectChanges && !hasFieldChanges) {
                this.showToast('Info', 'No changes to save.', 'info');
                return;
            }

            const responseJson = await saveTrackedConfiguration({
                objectsToActivate,
                objectsToDeactivate,
                fieldsToActivate,
                fieldsToDeactivate
            });

            // Parse the response
            const response = JSON.parse(responseJson);
            
            // Build success message
            let message = 'Configuration saved.';
            
            if (response.triggerDeploymentIds && response.triggerDeploymentIds.length > 0) {
                message += ` Deployed ${response.triggerDeploymentIds.length} trigger(s).`;
            }
            
            // Show any trigger errors as warnings
            if (response.triggerErrors && response.triggerErrors.length > 0) {
                this.showToast(
                    'Warning',
                    'Some triggers could not be deployed: ' + response.triggerErrors.join('; '),
                    'warning'
                );
            }

            this.showToast('Success', message, 'success');

            // Refresh to show updated tracking status
            await this.loadObjects();

        } catch (error) {
            this.showToast('Error', this.getErrorMessage(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    handleCancel() {
        // Reset to original tracked state
        this.loadObjects();
    }

    // Computed properties for template
    get hasSelectedObjects() {
        return this.objects.some(o => o.isSelected);
    }

    get selectedObjectCount() {
        // Count objects that are selected (checked)
        return this.objects.filter(o => o.isSelected).length;
    }

    get totalObjectCount() {
        return this.objects.length;
    }

    get saveButtonLabel() {
        return this.isSaving ? 'Saving...' : 'Save Configuration';
    }

    // Helper methods
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({
            title,
            message,
            variant
        }));
    }

    getErrorMessage(error) {
        if (error?.body?.message) {
            return error.body.message;
        }
        if (error?.message) {
            return error.message;
        }
        return 'An unexpected error occurred.';
    }
}