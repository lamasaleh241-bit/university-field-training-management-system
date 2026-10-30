# مخطط الكلاسات — نظام إدارة التدريب الميداني الجامعي

يعرض هذا المخطط الكلاسات الأساسية وخصائصها وعملياتها المقترحة وعلاقاتها. أسماء الكلاسات والخصائص والدوال بالإنجليزية، وشرح العلاقات بالعربية.

```mermaid
classDiagram
direction TB

class College {
  +UUID id
  +String name
  +String timezone
  +manageSpecialties()
}
class User {
  +UUID id
  +AccountStatus status
  +updateProfile()
}
class Role {
  +UUID id
  +String name
}
class Specialty {
  +UUID id
  +String name
}
class TrainingRequirements {
  +UUID id
  +int minimumHours
  +int maximumDailyHours
  +validateHours()
}
class TrainingOpportunity {
  +UUID id
  +OpportunityStatus status
  +publish()
  +close()
}
class TrainingSite {
  +UUID id
  +SiteApprovalStatus status
  +approve()
}
class TrainingApplication {
  +UUID id
  +ApplicationStatus status
  +submit()
  +review()
}
class ApplicationStatusHistory {
  +UUID id
  +ApplicationStatus status
  +DateTime changedAt
  +String reason
}
class Training {
  +UUID id
  +TrainingStatus status
  +complete()
  +endEarly()
}
class SupervisorAssignment {
  +UUID id
  +AssignmentStatus status
  +assign()
  +revoke()
}
class AttendanceRecord {
  +UUID id
  +AttendanceStatus status
  +DateTime checkInAt
  +DateTime checkOutAt
  +checkIn()
  +checkOut()
}
class AttendanceChangeRequest {
  +UUID id
  +AttendanceRequestType requestType
  +ReviewStatus status
  +submit()
  +review()
}
class SupervisorNote {
  +UUID id
  +createNote()
  +reviseNote()
}
class SupervisorNoteRevision {
  +UUID id
  +DateTime revisedAt
}
class FinalEvaluation {
  +UUID id
  +EvaluationStatus status
  +submit()
}
class EvaluationCriterion {
  +UUID id
  +String name
}
class EvaluationItem {
  +UUID evaluationId
  +UUID criterionId
  +EvaluationRating rating
}
class Conversation {
  +UUID id
  +ConversationStatus status
}
class Message {
  +UUID id
  +send()
}
class DisputeReport {
  +UUID id
  +DisputeStatus status
  +submit()
  +resolve()
}
class OfficialRequest {
  +UUID id
  +OfficialRequestStatus status
  +submit()
  +review()
}
class Notification {
  +UUID id
  +markRead()
}
class FileAsset {
  +UUID id
  +upload()
}
class AuditLog {
  +UUID id
  +DateTime occurredAt
  +String action
}

College "1" --> "0..*" User : "تضم"
College "1" --> "0..*" Specialty : "تدير"
User "0..*" --> "0..*" Role : "يمتلك أدوارا"
Specialty "1" --> "0..*" TrainingRequirements : "تحدد متطلباتها"
College "1" --> "0..*" TrainingOpportunity : "تدير فرصا"
College "1" --> "0..*" TrainingSite : "تعتمد مواقع"
TrainingOpportunity "0..*" --> "0..*" Specialty : "تستهدف"
TrainingOpportunity "0..*" --> "0..*" TrainingSite : "تستخدم"
User "1" --> "0..*" TrainingApplication : "يقدم"
TrainingOpportunity "1" --> "0..*" TrainingApplication : "تستقبل"
TrainingApplication "1" *-- "0..*" ApplicationStatusHistory : "سجل الحالات"
TrainingApplication "1" --> "0..1" Training : "ينتج عنها"
Training "1" --> "0..*" SupervisorAssignment : "إسنادات الإشراف"
User "1" --> "0..*" SupervisorAssignment : "يشرف"
Training "1" --> "0..*" AttendanceRecord : "سجلات الحضور"
Training "1" --> "0..*" AttendanceChangeRequest : "طلبات التصحيح"
AttendanceChangeRequest "0..*" --> "0..1" AttendanceRecord : "قد تصحح سجلا"
Training "1" --> "0..*" SupervisorNote : "ملاحظات الأداء"
SupervisorNote "1" *-- "0..*" SupervisorNoteRevision : "سجل التعديلات"
Training "1" --> "0..1" FinalEvaluation : "تقييم نهائي"
FinalEvaluation "1" *-- "0..*" EvaluationItem : "درجات المعايير"
EvaluationCriterion "1" --> "0..*" EvaluationItem : "معيار"
Training "1" --> "0..*" Conversation : "محادثات التدريب"
Conversation "1" *-- "0..*" Message : "الرسائل"
User "1" --> "0..*" Message : "يرسل"
Training "1" --> "0..*" DisputeReport : "بلاغات النزاع"
Training "1" --> "0..*" OfficialRequest : "طلبات رسمية"
User "1" --> "0..*" Notification : "يتلقى"
User "1" --> "0..*" FileAsset : "يرفع"
User "1" --> "0..*" AuditLog : "ينفذ إجراء مدققا"
```

## ملاحظات التصميم

- هذا Class Diagram منطقي للكلاسات الأساسية، وليس نسخا حرفيا لكل جدول في قاعدة البيانات.
- الجداول الوسيطة مثل `user_roles` و`opportunity_specialties` و`conversation_participants` ممثلة بعلاقات؛ التفاصيل المرجعية النهائية في `database.dbml`.
- العمليات المعروضة مقترحة وليست دوال منفذة.
- لكل تدريب تقييم نهائي واحد كحد أقصى؛ كل تقييم مرسل يحتوي على عناصر تقييم مرتبطة بالمعايير.
- طلب تصحيح الحضور قد لا يرتبط بسجل حضور سابق.
- الصلاحيات وعزل بيانات الكليات يخضعان لتصميم النظام وسياسات PostgreSQL RLS.
- طلب تغيير المشرف وتفعيل الحساب مفهومان مذكوران في النموذج المفاهيمي، لكن لا يظهران كجدولين مستقلين في مخطط DBML الحالي؛ يلزم حسم تمثيلهما قبل التنفيذ.